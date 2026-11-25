import Foundation

// Lets a computer the phone is plugged into take the Wired transfer config's recordings over the cable (server/pull.ps1) while the app is on screen, each frames file's segments as soon as the recording closes them, as the receiver takes them over Wi-Fi, and the rest once the recording is finished. It listens on port 8765 of the phone's loopback, which no other device on a network reaches and the computer reaches through usbmux, Apple's USB multiplexer, once the phone trusts it, and answers one HTTP/1.1 request per connection:
//   GET /recordings                       {"recordings": [{"key", "scan_id", "path", "files", "members"}, ...]}: each Wired transfer recording, recording or finished, under the key its files go by (RecordingInfo.uploadKey); its id, null while it records; the folder on the computer it goes to, null for the computer's Downloads folder; the files the phone holds of it now, each {"name", "size", "sha256"}, the closed segments not yet acknowledged and, once it is finished, its JSON files; and, once it is finished, its members as the upload manifest lists them, null before
//   GET /files/<key>/<file>               the bytes of one of those files
//   POST /acknowledged/<key>/<segment>    with X-Content-SHA256, the segment's: the computer holds the segment, whose file is then deleted from the phone
//   POST /stored/<scan_id>                the computer has stored the finished recording as its tar, and the recording is deleted from the phone
final class WiredServer {
    static let port: UInt16 = 8765
    private static let chunkBytes = 4 << 20
    private static let maxHeadBytes = 16 << 10

    // Called on the main queue: as a request for a finished recording (nil for one naming none) begins and ends, and once a recording the computer has stored has left the phone.
    var onRequest: ((String?, Bool) -> Void)?
    var onStored: ((RecordingInfo) -> Void)?

    // The listening socket's source, while listening; owned by the main queue.
    private var source: DispatchSourceRead?
    private let acceptQueue = DispatchQueue(label: "com.danielmao.RGBDScanner.cable")
    // The closed segments of each Wired transfer recording still recording, by key, with its folder; a recording leaves it once it is finished, its recording.json then listing them.
    private var recording: [String: (path: String?, segments: [Segment])] = [:]
    private let lock = NSLock()

    // Offers a segment a Wired transfer recording has just closed while it records.
    func add(_ segment: Segment, path: String?) {
        lock.withLock { recording[segment.uploadId, default: (path, [])].segments.append(segment) }
    }

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

    // A Wired transfer recording as the computer sees it: its key, its recording.json once it is finished, its folder, and the files the phone holds of it now.
    private struct Offered {
        let key: String
        let info: RecordingInfo?
        let path: String?
        let files: [(name: String, url: URL, size: Int, sha256: String)]
    }

    // The Wired transfer recordings: the finished ones, from their recording.json, then those still recording.
    private func offered() -> [Offered] {
        let directories = (try? FileManager.default.contentsOfDirectory(at: Recording.documents, includingPropertiesForKeys: nil)) ?? []
        let finished = directories.compactMap { try? RecordingInfo.load($0.appendingPathComponent(RecordingInfo.fileName)) }.filter(\.isWired)
        let finishedKeys = Set(finished.map(\.uploadKey))
        let live = lock.withLock {
            recording = recording.filter { !finishedKeys.contains($0.key) }
            return recording
        }
        let exists = { (url: URL) in FileManager.default.fileExists(atPath: url.path) }
        return finished.map { info in
            guard case .wired(let path)? = info.target else { preconditionFailure("\(info.id) listed as wired") }
            return Offered(key: info.uploadKey, info: info, path: path, files: info.members.map { (name: $0.name, url: info.url(of: $0), size: $0.size, sha256: $0.sha256) }.filter { exists($0.url) })
        } + live.sorted { $0.key < $1.key }.map { key, value in
            Offered(key: key, info: nil, path: value.path, files: value.segments.map { (name: $0.name, url: $0.file, size: $0.size, sha256: $0.sha256) }.filter { exists($0.url) })
        }
    }

    // Answers the connection's one request and closes it.
    private func serve(_ fd: Int32) {
        defer { close(fd) }
        // An accepted socket inherits the listening socket's non-blocking mode; a write to a computer that has gone fails instead of raising SIGPIPE.
        var yes: Int32 = 1
        guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK) == 0, setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size)) == 0 else { return }
        guard let (method, path, headers) = Self.readRequest(fd) else { return }
        let parts = path.split(separator: "/").map(String.init)
        let all = offered()
        // The finished recording a request names, by key or by id, for the app to show it being taken.
        let named = parts.count >= 2 ? all.first { $0.key == parts[1] || $0.info?.id == parts[1] }?.info?.id : nil
        DispatchQueue.main.async { self.onRequest?(named, true) }
        defer { DispatchQueue.main.async { self.onRequest?(named, false) } }
        switch (method, parts.count, parts.first) {
        case ("GET", 1, "recordings"?):
            let listing = all.map { offer -> [String: Any] in
                ["key": offer.key, "scan_id": offer.info?.id ?? NSNull(), "path": offer.path ?? NSNull(), "files": offer.files.map { ["name": $0.name, "size": $0.size, "sha256": $0.sha256] }, "members": offer.info?.manifestMembers ?? NSNull()]
            }
            Self.replyJSON(fd, 200, ["recordings": listing])
        case ("GET", 3, "files"?):
            guard let file = all.first(where: { $0.key == parts[1] })?.files.first(where: { $0.name == parts[2] }) else { return Self.replyJSON(fd, 404, ["error": "no such file"]) }
            Self.replyFile(fd, file.url, size: file.size)
        case ("POST", 3, "acknowledged"?):
            guard Recording.isSegment(parts[2]), let file = all.first(where: { $0.key == parts[1] })?.files.first(where: { $0.name == parts[2] }) else { return Self.replyJSON(fd, 404, ["error": "no such segment"]) }
            guard headers["x-content-sha256"] == file.sha256 else { return Self.replyJSON(fd, 409, ["error": "the segment's SHA-256 is \(file.sha256)"]) }
            do {
                try FileManager.default.removeItem(at: file.url)
            } catch {
                return Self.replyJSON(fd, 500, ["error": "cannot delete \(file.name): \(error.localizedDescription)"])
            }
            Self.replyJSON(fd, 200, ["deleted": file.name])
        case ("POST", 2, "stored"?):
            guard let info = all.first(where: { $0.info?.id == parts[1] })?.info else { return Self.replyJSON(fd, 404, ["error": "no such finished wired transfer recording"]) }
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

    // The method, path and headers, keyed in lowercase, of the request whose head the connection sends; nil when it sends none.
    private static func readRequest(_ fd: Int32) -> (String, String, [String: String])? {
        var head = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while head.range(of: Data("\r\n\r\n".utf8)) == nil {
            guard head.count < maxHeadBytes else { return nil }
            let n = read(fd, &buffer, buffer.count)
            guard n > 0 else { return nil }
            head.append(buffer, count: n)
        }
        // Lines end at CRLF, found in the bytes: a String holds "\r\n" as one Character.
        var lines: [String] = []
        var rest = head[...]
        while let end = rest.range(of: Data("\r\n".utf8)), end.lowerBound > rest.startIndex {
            lines.append(String(decoding: rest[..<end.lowerBound], as: UTF8.self))
            rest = rest[end.upperBound...]
        }
        let words = (lines.first ?? "").split(separator: " ").map(String.init)
        guard words.count == 3 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return (words[0], words[1], headers)
    }

    private static func replyJSON(_ fd: Int32, _ status: Int, _ body: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) else { preconditionFailure("a reply that is not JSON") }
        guard writeAll(fd, head(status, type: "application/json", length: data.count)) else { return }
        _ = writeAll(fd, data)
    }

    // Sends the file, which must hold size bytes; the computer checks them against the file's SHA-256.
    private static func replyFile(_ fd: Int32, _ url: URL, size: Int) {
        guard let file = try? FileHandle(forReadingFrom: url), (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) == size else { return replyJSON(fd, 500, ["error": "\(url.lastPathComponent) is missing or not \(size) bytes"]) }
        defer { try? file.close() }
        guard writeAll(fd, head(200, type: "application/octet-stream", length: size)) else { return }
        while let chunk = try? file.read(upToCount: chunkBytes), !chunk.isEmpty {
            guard writeAll(fd, chunk) else { return }
        }
    }

    private static func head(_ status: Int, type: String, length: Int) -> Data {
        let reason = [200: "OK", 404: "Not Found", 409: "Conflict", 500: "Internal Server Error"][status] ?? "Error"
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
