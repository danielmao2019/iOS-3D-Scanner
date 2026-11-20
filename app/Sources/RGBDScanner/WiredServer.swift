import Foundation

// Lets a computer the phone is plugged into take the Wired transfer config's recordings over the cable (server/pull.py), while the app is on screen. It listens on port 8765 of the phone's loopback, which no other device on a network reaches and the computer reaches through usbmux, Apple's USB multiplexer, once the phone trusts it, and answers one HTTP/1.1 request per connection:
//   GET /recordings                 {"recordings": [{"scan_id", "path", "members"}, ...]}: each finished recording of the Wired transfer config, the folder on the computer it goes to (null for the computer's Downloads folder) and its members as the upload manifest lists them, each frames file's segments grouped under it
//   GET /recordings/<scan_id>/<file>  the bytes of one of those members, a JSON file or a segment
//   POST /stored/<scan_id>          the computer has stored the recording, which is then deleted from the phone
final class WiredServer {
    static let port: UInt16 = 8765
    private static let chunkBytes = 4 << 20
    private static let maxHeadBytes = 16 << 10

    // Called on the main queue: as a request for a recording (nil for one naming none) begins and ends, and once a recording the computer has stored has left the phone.
    var onRequest: ((String?, Bool) -> Void)?
    var onStored: ((RecordingInfo) -> Void)?

    // The listening socket's source, while listening; owned by the main queue.
    private var source: DispatchSourceRead?
    private let acceptQueue = DispatchQueue(label: "com.danielmao.RGBDScanner.cable")

    // Starts listening, unless it already is.
    func start() throws {
        guard source == nil else { return }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Self.posixError("cannot open a socket") }
        // Reusing the port, a listener started again as the app comes back on screen binds it at once.
        var yes: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            let error = Self.posixError("cannot reuse port \(Self.port)")
            close(fd)
            throw error
        }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = Self.port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0, listen(fd, 8) == 0, fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else {
            let error = Self.posixError("cannot listen on port \(Self.port)")
            close(fd)
            throw error
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
        source.setEventHandler { [weak self] in
            while true {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { return }
                DispatchQueue.global(qos: .userInitiated).async { self?.serve(client) }
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    // Stops listening; requests already open run on until iOS suspends the app.
    func stop() {
        source?.cancel()
        source = nil
    }

    // Answers the connection's one request and closes it.
    private func serve(_ fd: Int32) {
        defer { close(fd) }
        // An accepted socket inherits the listening socket's non-blocking mode; a write to a computer that has gone fails instead of raising SIGPIPE.
        var yes: Int32 = 1
        guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK) == 0, setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size)) == 0 else { return }
        guard let (method, path) = Self.readRequestLine(fd) else { return }
        let parts = path.split(separator: "/").map(String.init)
        let id = parts.count >= 2 ? parts[1] : nil
        DispatchQueue.main.async { self.onRequest?(id, true) }
        defer { DispatchQueue.main.async { self.onRequest?(id, false) } }
        switch (method, parts.count, parts.first) {
        case ("GET", 1, "recordings"?):
            let listing = Self.recordings().map { info -> [String: Any] in
                guard case .wired(let folder)? = info.target else { preconditionFailure("\(info.id) listed as wired") }
                return ["scan_id": info.id, "path": folder ?? NSNull(), "members": info.manifestMembers]
            }
            Self.replyJSON(fd, 200, ["recordings": listing])
        case ("GET", 3, "recordings"?):
            guard let info = Self.recordings().first(where: { $0.id == parts[1] }), let member = info.members.first(where: { $0.name == parts[2] }) else { return Self.replyJSON(fd, 404, ["error": "no such wired transfer recording or member"]) }
            Self.replyFile(fd, info.url(of: member), size: member.size)
        case ("POST", 2, "stored"?):
            guard let info = Self.recordings().first(where: { $0.id == parts[1] }) else { return Self.replyJSON(fd, 404, ["error": "no such wired transfer recording"]) }
            do {
                try info.removeFromPhone()
            } catch {
                return Self.replyJSON(fd, 500, ["error": "cannot delete \(info.id) from the phone: \(error.localizedDescription)"])
            }
            Self.replyJSON(fd, 200, ["deleted": info.id])
            DispatchQueue.main.async { self.onStored?(info) }
        default:
            Self.replyJSON(fd, 404, ["error": "not found"])
        }
    }

    // The finished recordings of the Wired transfer config, from their recording.json.
    private static func recordings() -> [RecordingInfo] {
        let directories = (try? FileManager.default.contentsOfDirectory(at: Recording.documents, includingPropertiesForKeys: nil)) ?? []
        return directories.compactMap { try? RecordingInfo.load($0.appendingPathComponent(RecordingInfo.fileName)) }.filter(\.isWired)
    }

    // The method and path of the request whose head the connection sends; nil when it sends none.
    private static func readRequestLine(_ fd: Int32) -> (String, String)? {
        var head = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while head.range(of: Data("\r\n\r\n".utf8)) == nil {
            guard head.count < maxHeadBytes else { return nil }
            let n = read(fd, &buffer, buffer.count)
            guard n > 0 else { return nil }
            head.append(buffer, count: n)
        }
        // The request line ends at the first CRLF, found in the bytes: a String holds "\r\n" as one Character.
        guard let end = head.range(of: Data("\r\n".utf8)) else { return nil }
        let words = String(decoding: head[..<end.lowerBound], as: UTF8.self).split(separator: " ").map(String.init)
        guard words.count == 3 else { return nil }
        return (words[0], words[1])
    }

    private static func replyJSON(_ fd: Int32, _ status: Int, _ body: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) else { preconditionFailure("a reply that is not JSON") }
        guard writeAll(fd, head(status, type: "application/json", length: data.count)) else { return }
        _ = writeAll(fd, data)
    }

    // Sends the file, which must hold size bytes; the computer checks them against the member's SHA-256.
    private static func replyFile(_ fd: Int32, _ url: URL, size: Int) {
        guard let file = try? FileHandle(forReadingFrom: url), (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) == size else { return replyJSON(fd, 500, ["error": "\(url.lastPathComponent) is missing or not \(size) bytes"]) }
        defer { try? file.close() }
        guard writeAll(fd, head(200, type: "application/octet-stream", length: size)) else { return }
        while let chunk = try? file.read(upToCount: chunkBytes), !chunk.isEmpty {
            guard writeAll(fd, chunk) else { return }
        }
    }

    private static func head(_ status: Int, type: String, length: Int) -> Data {
        let reason = [200: "OK", 404: "Not Found", 500: "Internal Server Error"][status] ?? "Error"
        return Data("HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(type)\r\nContent-Length: \(length)\r\nConnection: close\r\n\r\n".utf8)
    }

    // Whether every byte was written before the computer closed the connection.
    private static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let n = write(fd, bytes.baseAddress! + offset, bytes.count - offset)
                guard n > 0 else { return false }
                offset += n
            }
            return true
        }
    }

    private static func posixError(_ what: String) -> RecorderError { RecorderError("\(what): \(String(cString: strerror(errno)))") }
}
