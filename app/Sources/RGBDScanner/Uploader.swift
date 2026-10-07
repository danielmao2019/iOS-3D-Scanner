import CryptoKit
import Foundation

// Uploads finished recordings to the receiver (server/receive.py) through one background URLSession, which iOS carries on while the app is suspended, relaunching it in the background to report the tasks that ended; a force quit from the app switcher cancels them, as iOS does for every app. Each member the receiver has not acknowledged goes up from its file as PUT /upload/<id>/<member>, with its SHA-256 from recording.json in X-Content-SHA256; once every member is acknowledged, PUT /upload/<id>/manifest.json from the manifest written beside them, the members in the archive's order with their sizes and SHA-256s, lets the receiver assemble the archive. Each acknowledgement is recorded in recording.json at once, so an upload cut short resumes where it stopped and never resends an acknowledged member.
final class Uploader: NSObject, URLSessionDataDelegate {
    // The one uploader; the app delegate makes it at every launch, so its background session reconnects to the tasks iOS carried on while the app was not running.
    static let shared = Uploader()
    private static let sessionIdentifier = "com.danielmao.RGBDScanner.upload"
    private static let manifestName = "manifest.json"

    // Set when iOS launches the app to report the session's events; called once they are all delivered.
    var backgroundEventsHandled: (() -> Void)?

    // Everything below is owned by the main queue, the session's delegate queue.
    private var session: URLSession!
    // The recording.json of each recording this run of the app has uploaded or heard of, as last written.
    private var infos: [String: RecordingInfo] = [:]
    // The progress and completion callbacks of the uploads this run of the app is showing, by recording.
    private var observers: [String: (onProgress: (Double) -> Void, completion: (Result<Void, Error>) -> Void)] = [:]
    // The recording and bytes sent of each member task in flight, by task identifier.
    private var sent: [Int: (id: String, bytes: Int64)] = [:]
    // The receiver's reply to each task in flight, as it arrives.
    private var replies: [Int: Data] = [:]

    private override init() {
        super.init()
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 24 * 3600
        session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }

    // Starts the PUTs of the recording's members the receiver has not acknowledged and that are not already on their way, or of its manifest once they are all acknowledged; onProgress and completion are called on the main queue.
    func upload(_ id: String, server: String, onProgress: @escaping (Double) -> Void, completion: @escaping (Result<Void, Error>) -> Void) {
        let base = server.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let root = URL(string: "\(base)/upload/\(id)/") else { return completion(.failure(RecorderError("bad server URL"))) }
        do {
            // The receiver may have acknowledged the manifest since the gallery last read recording.json.
            if try load(id).uploaded { return completion(.success(())) }
        } catch {
            return completion(.failure(error))
        }
        observers[id] = (onProgress, completion)
        session.getAllTasks { tasks in
            let underway = Set(tasks.filter { $0.state == .running || $0.state == .suspended }.compactMap(\.taskDescription))
            DispatchQueue.main.async {
                // As last written: a task that ended after the snapshot is either acknowledged here or was underway in it.
                guard let info = self.infos[id] else { preconditionFailure("\(id) was loaded before its tasks were listed") }
                for member in info.members where !member.uploaded && !underway.contains(Self.describe(id, member.name)) {
                    self.start(info.directory.appendingPathComponent(member.name), to: root.appendingPathComponent(member.name), sha256: member.sha256, as: Self.describe(id, member.name))
                }
                if info.members.allSatisfy(\.uploaded) && !underway.contains(Self.describe(id, Self.manifestName)) {
                    do { try self.startManifest(info, root: root) } catch { self.fail(id, error) }
                }
                self.reportProgress(id)
            }
        }
    }

    // A task's description, which tells even a relaunched app which recording and file the task carries.
    private static func describe(_ id: String, _ name: String) -> String { "\(id)/\(name)" }

    // Starts the PUT of a file with its SHA-256.
    private func start(_ file: URL, to url: URL, sha256: String, as description: String) {
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue(Secrets.uploadToken, forHTTPHeaderField: "X-Upload-Token")
        request.setValue(sha256, forHTTPHeaderField: "X-Content-SHA256")
        let task = session.uploadTask(with: request, fromFile: file)
        task.taskDescription = description
        task.resume()
    }

    // Writes the recording's manifest beside its members, the members in the archive's order with their sizes and SHA-256s, and starts its PUT to root/manifest.json.
    private func startManifest(_ info: RecordingInfo, root: URL) throws {
        let members = info.members.map { ["name": $0.name, "size": $0.size, "sha256": $0.sha256] as [String: Any] }
        let manifest = try JSONSerialization.data(withJSONObject: ["members": members], options: [.prettyPrinted, .sortedKeys])
        try manifest.write(to: info.manifest, options: .atomic)
        start(info.manifest, to: root.appendingPathComponent(Self.manifestName), sha256: SHA256.hash(data: manifest).hex, as: Self.describe(info.id, Self.manifestName))
    }

    // A recording's recording.json as last written, read from disk the first time.
    private func load(_ id: String) throws -> RecordingInfo {
        if let info = infos[id] { return info }
        let info = try RecordingInfo.load(RecordingInfo.directory(id).appendingPathComponent(RecordingInfo.fileName))
        infos[id] = info
        return info
    }

    private func save(_ info: RecordingInfo) throws {
        try info.write(to: info.file)
        infos[info.id] = info
    }

    // Tells the recording's observer, if any, the fraction of its members' bytes acknowledged or sent so far.
    private func reportProgress(_ id: String) {
        guard let observer = observers[id], let info = infos[id] else { return }
        let total = info.members.reduce(Int64(0)) { $0 + Int64($1.size) }
        let acknowledged = info.members.filter(\.uploaded).reduce(Int64(0)) { $0 + Int64($1.size) }
        let inFlight = sent.values.filter { $0.id == id }.reduce(Int64(0)) { $0 + $1.bytes }
        observer.onProgress(Double(acknowledged + inFlight) / Double(total))
    }

    // Tells the recording's observer, if any, that its upload failed; a retry starts what is left.
    private func fail(_ id: String, _ error: Error) {
        observers.removeValue(forKey: id)?.completion(.failure(error))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        let (id, name) = Self.parse(task)
        // The manifest's few bytes are not part of the members' total.
        guard name != Self.manifestName else { return }
        sent[task.taskIdentifier] = (id, totalBytesSent)
        reportProgress(id)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        replies[dataTask.taskIdentifier, default: Data()].append(data)
    }

    // Records the receiver's acknowledgement of a member in recording.json, starting the manifest once every member is acknowledged, or of the manifest, which completes the recording's upload.
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (id, name) = Self.parse(task)
        sent[task.taskIdentifier] = nil
        let reply = String(decoding: replies.removeValue(forKey: task.taskIdentifier) ?? Data(), as: UTF8.self)
        if let error = error as NSError? {
            let underlying = (error.userInfo[NSUnderlyingErrorKey] as? NSError).map { " [\($0.domain) \($0.code)]" } ?? ""
            return fail(id, RecorderError("\(name): \(error.localizedDescription) (\(error.domain) \(error.code))\(underlying)"))
        }
        let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { return fail(id, RecorderError("server replied \(status) to \(name): \(reply)")) }
        do {
            var info = try load(id)
            if name == Self.manifestName {
                info.uploaded = true
                try save(info)
                observers.removeValue(forKey: id)?.completion(.success(()))
                return
            }
            guard let i = info.members.firstIndex(where: { $0.name == name }) else { preconditionFailure("a task for \(name), which \(id) has no member of") }
            // A member sent twice, which only its first acknowledgement records.
            guard !info.members[i].uploaded else { return }
            info.members[i].uploaded = true
            try save(info)
            reportProgress(id)
            guard info.members.allSatisfy(\.uploaded) else { return }
            guard let url = task.originalRequest?.url else { preconditionFailure("a task without its request") }
            // The manifest goes where its members went.
            try startManifest(info, root: url.deletingLastPathComponent())
        } catch {
            fail(id, error)
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        backgroundEventsHandled?()
        backgroundEventsHandled = nil
    }

    // The recording and file a task carries, from its description.
    private static func parse(_ task: URLSessionTask) -> (id: String, name: String) {
        guard let parts = task.taskDescription?.split(separator: "/"), parts.count == 2 else { preconditionFailure("a task described as \(task.taskDescription ?? "nothing"), not <id>/<file>") }
        return (String(parts[0]), String(parts[1]))
    }
}
