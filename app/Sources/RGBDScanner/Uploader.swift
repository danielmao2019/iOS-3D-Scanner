import CryptoKit
import Foundation

// Uploads recordings to the receiver (server/receive.py) through one background URLSession, which iOS carries on while the app is suspended, relaunching it in the background to report the tasks that ended; a force quit from the app switcher cancels them, as iOS does for every app. Every file goes up from its file as PUT /upload/<key>/<file> to the address server/users.json gives the server of the recording's destination, under its upload key (RecordingInfo.uploadKey), with its SHA-256 in X-Content-SHA256 and the destination's data root in X-Data-Root: from 5.0.3 each segment of a frames file as soon as the recording closes it, while it records, and once the recording is finished every member the receiver has not acknowledged; once every member is acknowledged, PUT /upload/<key>/manifest.json from the manifest written beside them, the members in recording.json's order with their sizes and SHA-256s, each frames file's segments grouped under it, and from 5.0.3 the recording's id, lets the receiver complete the recording. The receiver's 200 is the file's safe arrival: a segment's file is deleted then, so its frames leave the phone, and a finished recording's member is recorded as acknowledged in recording.json at once, so an upload cut short resumes where it stopped and never resends an acknowledged member.
final class Uploader: NSObject, URLSessionDataDelegate {
    // The one uploader; the app delegate makes it at every launch, so its background session reconnects to the tasks iOS carried on while the app was not running.
    static let shared = Uploader()
    private static let sessionIdentifier = "com.danielmao.RGBDScanner.upload"
    private static let manifestName = "manifest.json"
    // A segment whose upload failed while its recording records goes up again after this long; once the recording is finished, its upload retries it.
    private static let segmentRetrySeconds = 10.0
    // The receiver writes a recording's archive after acknowledging its manifest, and is asked again this often until it has.
    private static let storedRetrySeconds = 5.0

    // Set when iOS launches the app to report the session's events; called once they are all delivered.
    var backgroundEventsHandled: (() -> Void)?

    // Everything below is owned by the main queue, the session's delegate queue.
    private var session: URLSession!
    // The recording.json of each finished recording this run of the app has uploaded or heard of, as last written, by id.
    private var infos: [String: RecordingInfo] = [:]
    // The progress and completion callbacks of the uploads this run of the app is showing, by recording.
    private var observers: [String: (onProgress: (Double) -> Void, completion: (Result<Void, Error>) -> Void)] = [:]
    // The finished recording and bytes sent of each member task in flight, by task identifier.
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

    // Starts the PUTs of the finished recording's members the receiver has not acknowledged and that are not already on their way, or of its manifest once they are all acknowledged; onProgress and completion are called on the main queue.
    func upload(_ id: String, onProgress: @escaping (Double) -> Void, completion: @escaping (Result<Void, Error>) -> Void) {
        let info: RecordingInfo
        do {
            info = try load(id)
        } catch {
            return completion(.failure(error))
        }
        guard case .upload(let destination)? = info.target else { return completion(.failure(RecorderError(info.target == nil ? "recorded before 5.0.3, with no config to upload to" : "kept on this phone"))) }
        guard let address = UsersFile.address(of: destination.server), let root = Self.root(address, info.uploadKey) else { return completion(.failure(RecorderError("this build gives no address for the server \(destination.server)"))) }
        observers[id] = (onProgress, completion)
        if info.uploaded { return confirmStored(info, destination: destination) }
        session.getAllTasks { tasks in
            let underway = Set(tasks.filter { $0.state == .running || $0.state == .suspended }.compactMap(\.taskDescription))
            DispatchQueue.main.async {
                // As last written: a task that ended after the snapshot is either acknowledged here or was underway in it.
                guard let info = self.infos[id] else { preconditionFailure("\(id) was loaded before its tasks were listed") }
                let key = info.uploadKey
                do {
                    let current = try self.acknowledgingDeletedSegments(info)
                    for member in current.members where !member.uploaded && !underway.contains(Self.describe(key, member.name)) {
                        self.start(current.url(of: member), to: root.appendingPathComponent(member.name), sha256: member.sha256, dataRoot: destination.dataRoot, as: Self.describe(key, member.name))
                    }
                    if current.members.allSatisfy(\.uploaded) && !underway.contains(Self.describe(key, Self.manifestName)) { try self.startManifest(current, root: root, dataRoot: destination.dataRoot) }
                } catch {
                    self.fail(id, error)
                }
                self.reportProgress(id)
            }
        }
    }

    // Asks the receiver until it answers that the recording's archive is stored under its data root, then deletes the recording from the phone and completes its upload; a refusal fails the upload, and no answer is asked again.
    private func confirmStored(_ info: RecordingInfo, destination: UploadDestination) {
        observers[info.id]?.onProgress(1)
        guard let address = UsersFile.address(of: destination.server), let url = URL(string: "\(address.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/stored/\(info.id)") else { return fail(info.id, RecorderError("this build gives no address for the server \(destination.server)")) }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue(Secrets.uploadToken, forHTTPHeaderField: "X-Upload-Token")
        request.setValue(destination.dataRoot, forHTTPHeaderField: "X-Data-Root")
        URLSession.shared.dataTask(with: request) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode
            let stored = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["stored"] as? Bool
            DispatchQueue.main.async { [self] in
                if let status, status != 200 { return fail(info.id, RecorderError("server replied \(status) to the stored check: \(String(decoding: data ?? Data(), as: UTF8.self))")) }
                guard stored == true else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + Self.storedRetrySeconds) { self.confirmStored(info, destination: destination) }
                    return
                }
                do {
                    try FileManager.default.removeItem(at: info.directory)
                    if let segments = info.segmentsDirectory, FileManager.default.fileExists(atPath: segments.path) { try FileManager.default.removeItem(at: segments) }
                    infos[info.id] = nil
                    observers.removeValue(forKey: info.id)?.completion(.success(()))
                } catch {
                    fail(info.id, error)
                }
            }
        }.resume()
    }

    // Asks the destination's receiver for the recordings its data root holds; completion is called on the main queue.
    func listRecordings(on destination: UploadDestination, completion: @escaping (Result<[ServerRecording], Error>) -> Void) {
        guard let address = UsersFile.address(of: destination.server), let url = URL(string: "\(address.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/recordings") else { return completion(.failure(RecorderError("this build gives no address for the server \(destination.server)"))) }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue(Secrets.uploadToken, forHTTPHeaderField: "X-Upload-Token")
        request.setValue(destination.dataRoot, forHTTPHeaderField: "X-Data-Root")
        URLSession.shared.dataTask(with: request) { data, response, error in
            let result = Result<[ServerRecording], Error> {
                if let error { throw error }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 200, let data else { throw RecorderError("server replied \(status): \(String(decoding: data ?? Data(), as: UTF8.self))") }
                struct Listing: Decodable { let recordings: [ServerRecording] }
                let decoder = JSONDecoder()
                decoder.keyDecodingStrategy = .convertFromSnakeCase
                decoder.dateDecodingStrategy = .iso8601
                return try decoder.decode(Listing.self, from: data).recordings
            }
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }

    // Starts the PUT of a segment its recording has just closed, while it records.
    func uploadSegment(_ segment: Segment, to destination: UploadDestination) {
        // A segment that cannot go up stays on the phone, and the recording's upload reports why once it is finished.
        guard let address = UsersFile.address(of: destination.server), let root = Self.root(address, segment.uploadId) else { return }
        start(segment.file, to: root.appendingPathComponent(segment.name), sha256: segment.sha256, dataRoot: destination.dataRoot, as: Self.describe(segment.uploadId, segment.name))
    }

    // Where a recording's files go: <address>/upload/<key>/.
    private static func root(_ address: String, _ key: String) -> URL? {
        let base = address.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return URL(string: "\(base)/upload/\(key)/")
    }

    // A task's description, which tells even a relaunched app which recording's key and file the task carries.
    private static func describe(_ key: String, _ name: String) -> String { "\(key)/\(name)" }

    // Starts the PUT of a file with its SHA-256, into the data root.
    private func start(_ file: URL, to url: URL, sha256: String, dataRoot: String, as description: String) {
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue(Secrets.uploadToken, forHTTPHeaderField: "X-Upload-Token")
        request.setValue(sha256, forHTTPHeaderField: "X-Content-SHA256")
        request.setValue(dataRoot, forHTTPHeaderField: "X-Data-Root")
        let task = session.uploadTask(with: request, fromFile: file)
        task.taskDescription = description
        task.resume()
    }

    // The recording with each segment whose file is gone recorded as acknowledged, as the receiver acknowledged it, maybe before recording.json was written: a segment's file is deleted only then.
    private func acknowledgingDeletedSegments(_ info: RecordingInfo) throws -> RecordingInfo {
        var info = info
        let acknowledged = info.members.indices.filter { !info.members[$0].uploaded && Recording.isSegment(info.members[$0].name) && !FileManager.default.fileExists(atPath: info.url(of: info.members[$0]).path) }
        guard !acknowledged.isEmpty else { return info }
        for i in acknowledged { info.members[i].uploaded = true }
        try save(info)
        return info
    }

    // Writes the recording's manifest beside its members, the members in recording.json's order with their sizes and SHA-256s, each frames file's consecutive segments grouped under it, and starts its PUT to root/manifest.json, into the data root.
    private func startManifest(_ info: RecordingInfo, root: URL, dataRoot: String) throws {
        var members: [[String: Any]] = []
        for member in info.members {
            let entry: [String: Any] = ["name": member.name, "size": member.size, "sha256": member.sha256]
            guard Recording.isSegment(member.name) else {
                members.append(entry)
                continue
            }
            // <frames file>.<index, 6 digits>
            let file = String(member.name.dropLast(7))
            if members.last?["name"] as? String == file, var segments = members.last?["segments"] as? [[String: Any]] {
                segments.append(entry)
                members[members.count - 1]["segments"] = segments
            } else {
                members.append(["name": file, "segments": [entry]])
            }
        }
        var manifest: [String: Any] = ["members": members]
        // The receiver names the recording by its id, which from 5.0.3 is not the key its files went under.
        if info.uploadId != nil { manifest["scan_id"] = info.id }
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: info.manifest, options: .atomic)
        start(info.manifest, to: root.appendingPathComponent(Self.manifestName), sha256: SHA256.hash(data: data).hex, dataRoot: dataRoot, as: Self.describe(info.uploadKey, Self.manifestName))
    }

    // A recording's recording.json as last written, read from disk the first time.
    private func load(_ id: String) throws -> RecordingInfo {
        if let info = infos[id] { return info }
        let info = try RecordingInfo.load(RecordingInfo.directory(id).appendingPathComponent(RecordingInfo.fileName))
        infos[id] = info
        return info
    }

    // The finished recording whose files go under key, from those read so far or from the recording.json naming it; nil while the recording records or is being finished, its work directory still there.
    private func finished(_ key: String) -> RecordingInfo? {
        if let info = infos.values.first(where: { $0.uploadKey == key }) { return info }
        guard !FileManager.default.fileExists(atPath: Recording.documents.appendingPathComponent("work").appendingPathComponent(key).path) else { return nil }
        let directories = (try? FileManager.default.contentsOfDirectory(at: Recording.documents, includingPropertiesForKeys: nil)) ?? []
        for directory in directories {
            // A recording apps 4.1 to 4.5 finished, its recording.json listing no members, does not decode until the app lists them.
            guard let info = try? RecordingInfo.load(directory.appendingPathComponent(RecordingInfo.fileName)), info.uploadKey == key else { continue }
            infos[info.id] = info
            return info
        }
        return nil
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
        let (key, name) = Self.parse(task)
        // The manifest's few bytes are not part of the members' total, and a recording still recording shows no upload.
        guard name != Self.manifestName, let info = finished(key) else { return }
        sent[task.taskIdentifier] = (info.id, totalBytesSent)
        reportProgress(info.id)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        replies[dataTask.taskIdentifier, default: Data()].append(data)
    }

    // On the receiver's acknowledgement of a segment, deletes its file; of a finished recording's member, records it in recording.json, starting the manifest once every member is acknowledged; of the manifest, confirms the recording is stored and deletes it from the phone. A failed segment of a recording still recording goes up again.
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (key, name) = Self.parse(task)
        sent[task.taskIdentifier] = nil
        let reply = String(decoding: replies.removeValue(forKey: task.taskIdentifier) ?? Data(), as: UTF8.self)
        let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        var failure: Error?
        if let error = error as NSError? {
            let underlying = (error.userInfo[NSUnderlyingErrorKey] as? NSError).map { " [\($0.domain) \($0.code)]" } ?? ""
            failure = RecorderError("\(name): \(error.localizedDescription) (\(error.domain) \(error.code))\(underlying)")
        } else if status != 200 {
            failure = RecorderError("server replied \(status) to \(name): \(reply)")
        }
        let info = finished(key)
        if let failure {
            if let info { return fail(info.id, failure) }
            guard Recording.isSegment(name), let request = task.originalRequest, let url = request.url, let sha256 = request.value(forHTTPHeaderField: "X-Content-SHA256"), let dataRoot = request.value(forHTTPHeaderField: "X-Data-Root") else { return }
            let file = Recording.segmentsDirectory(key).appendingPathComponent(name)
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.segmentRetrySeconds) { [self] in
                guard finished(key) == nil, FileManager.default.fileExists(atPath: file.path) else { return }
                start(file, to: url, sha256: sha256, dataRoot: dataRoot, as: Self.describe(key, name))
            }
            return
        }
        if Recording.isSegment(name) {
            // The receiver holds the segment, so its frames leave the phone; a file left by a failed delete is sent again, which the receiver takes again.
            try? FileManager.default.removeItem(at: Recording.segmentsDirectory(key).appendingPathComponent(name))
        }
        // While the recording records, the deleted file records the acknowledgement.
        guard var info else { return }
        do {
            if name == Self.manifestName {
                info.uploaded = true
                try save(info)
                // A recording 5.0.3 or 5.1 sent to a server alone stays on this phone, as RecordingTarget reads it.
                guard case .upload(let destination)? = info.target else { observers.removeValue(forKey: info.id)?.completion(.success(())); return }
                return confirmStored(info, destination: destination)
            }
            guard let i = info.members.firstIndex(where: { $0.name == name }) else { preconditionFailure("a task for \(name), which \(info.id) has no member of") }
            // A member sent twice, which only its first acknowledgement records.
            guard !info.members[i].uploaded else { return }
            info.members[i].uploaded = true
            try save(info)
            reportProgress(info.id)
            guard info.members.allSatisfy(\.uploaded) else { return }
            guard let url = task.originalRequest?.url, let dataRoot = task.originalRequest?.value(forHTTPHeaderField: "X-Data-Root") else { preconditionFailure("a task without its request") }
            // The manifest goes where its members went.
            try startManifest(info, root: url.deletingLastPathComponent(), dataRoot: dataRoot)
        } catch {
            fail(info.id, error)
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        backgroundEventsHandled?()
        backgroundEventsHandled = nil
    }

    // The recording's upload key and the file a task carries, from its description.
    private static func parse(_ task: URLSessionTask) -> (key: String, name: String) {
        guard let parts = task.taskDescription?.split(separator: "/"), parts.count == 2 else { preconditionFailure("a task described as \(task.taskDescription ?? "nothing"), not <key>/<file>") }
        return (String(parts[0]), String(parts[1]))
    }
}
