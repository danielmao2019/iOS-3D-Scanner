import AVFoundation
import SwiftUI

@main
struct RGBDScannerApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

// Makes the uploader at every launch, including one iOS makes in the background to report its session's events, and hands it the call that tells iOS those events are handled.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Its background session reconnects, as it is made, to the tasks iOS carried on while the app was not running.
        _ = Uploader.shared
        return true
    }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        Uploader.shared.backgroundEventsHandled = completionHandler
    }
}

// Where a recording's upload stands; a recording has at most one upload in flight.
enum UploadState: Equatable {
    case notUploaded
    case inProgress(String)
    case uploaded
    case failed(String)

    var canStart: Bool {
        switch self {
        case .notUploaded, .failed: return true
        case .inProgress, .uploaded: return false
        }
    }

    var label: String {
        switch self {
        case .notUploaded: return "not uploaded"
        case .inProgress(let step): return step
        case .uploaded: return "uploaded ✓"
        case .failed(let message): return "upload failed: \(message)"
        }
    }
}

// A finished recording's Documents/<id>/recording.json, beside the recording's files, its members, in that directory; the uploader rewrites it as the receiver acknowledges each member.
struct RecordingInfo: Codable {
    let id: String
    let name: String
    let namedByUser: Bool
    let startTime: Date
    let durationSeconds: Double
    let camera: DepthCamera
    // The recording's files, in the order the manifest lists them.
    var members: [Member]
    // Whether the receiver has acknowledged the manifest, and so holds the whole recording.
    var uploaded: Bool

    // One of the recording's files: its name, its size in bytes, its SHA-256 as 64 lowercase hex characters, and whether the receiver has acknowledged it.
    struct Member: Codable {
        let name: String
        let size: Int
        let sha256: String
        var uploaded: Bool
    }

    static let fileName = "recording.json"
    // A finished recording's directory, Documents/<id>/.
    static func directory(_ id: String) -> URL { Recording.documents.appendingPathComponent(id, isDirectory: true) }
    var directory: URL { Self.directory(id) }
    var file: URL { directory.appendingPathComponent(Self.fileName) }
    // The manifest the uploader writes for the receiver once every member is acknowledged; never one of the recording's files.
    var manifest: URL { directory.appendingPathComponent("manifest.json") }

    func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    static func load(_ file: URL) throws -> RecordingInfo {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(RecordingInfo.self, from: Data(contentsOf: file))
    }
}

// A gallery entry: a finished recording, the total size of its members, and where its upload stands.
struct RecordingFile: Identifiable {
    var info: RecordingInfo
    var upload: UploadState
    var id: String { info.id }
    var size: Int64 { info.members.reduce(0) { $0 + Int64($1.size) } }
    // Not while its upload is in flight.
    var canDelete: Bool { upload.canStart || upload == .uploaded }
}

final class AppModel: ObservableObject {
    @Published var camera: DepthCamera = .front
    @Published var formatSummary = ""
    @Published var stats = CaptureStats()
    // From Start or Later until the recording is running.
    @Published var isStarting = false
    @Published var isRecording = false
    @Published var recordingStart = Date()
    @Published var message = ""
    @Published var files: [RecordingFile] = []
    @Published var server: String {
        didSet { UserDefaults.standard.set(server, forKey: "server") }
    }
    @Published var showsDepth = false {
        didSet {
            recorder.depthPreview.isEnabled = showsDepth
            if !showsDepth { depthFrame = nil }
        }
    }
    @Published var depthFrame: DepthFrame?
    @Published var asksNameBeforeStart = false
    @Published var asksNameAfterStop = false
    @Published var nameDraft = ""
    // The recording whose delete is awaiting confirmation.
    @Published var pendingDelete: RecordingFile?

    let availableCameras: [DepthCamera]
    let recorder: Recorder
    // The name given when the recording started; nil when naming was deferred.
    private var userName: String?
    // A stopped recording waiting for its name, with why it stopped when it was not the Stop button.
    private var unnamed: (recording: Recording, stopNote: String?)?

    init() {
        server = UserDefaults.standard.string(forKey: "server") ?? Secrets.server
        availableCameras = DepthCamera.allCases.filter(\.isAvailable)
        recorder = Recorder(cameras: availableCameras)
        if let first = availableCameras.first { camera = first }
        recorder.onStats = { [weak self] in self?.stats = $0 }
        recorder.depthPreview.onFrame = { [weak self] frame in
            guard let self, self.showsDepth else { return }
            self.depthFrame = frame
        }
        recorder.onInterruption = { [weak self] reason in self?.stopRecording(because: reason) }
        refreshFiles()
        // A recording not yet uploaded resumes: the members the receiver acknowledged, and those still on their way, are not sent again.
        files.filter { !$0.info.uploaded }.forEach { upload($0.id) }
        recoverLeftovers()
        addMissingMembers()
    }

    // Lists the members of the recordings apps 4.1 to 4.5 finished, which the gallery shows once they have them; one not yet uploaded then uploads.
    private func addMissingMembers() {
        let directories = Recording.withoutMembers()
        DispatchQueue.global(qos: .utility).async {
            for directory in directories {
                let result = Result { try Recording.addMembers(directory) }
                DispatchQueue.main.async {
                    switch result {
                    case .success(let info):
                        self.refreshFiles()
                        if !info.uploaded { self.upload(info.id) }
                    case .failure(let error):
                        self.message = "Unreadable \(directory.lastPathComponent): \(error.localizedDescription)"
                    }
                }
            }
        }
    }

    // Finishes, under their date and time, the recordings a closed app or a failed finish left unfinished.
    private func recoverLeftovers() {
        let directories = Recording.leftovers()
        DispatchQueue.global(qos: .utility).async {
            for directory in directories {
                let result = Result { try Recording.recover(directory) }
                DispatchQueue.main.async { self.finished(result, note: "Recovered an unfinished recording") }
            }
        }
    }

    func startPreview() {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            DispatchQueue.main.async {
                guard granted else { self.message = "Camera access denied"; return }
                guard !self.availableCameras.isEmpty else { self.message = "This phone has no depth camera"; return }
                self.formatSummary = ""
                self.recorder.start(camera: self.camera) { result in
                    switch result {
                    case .success(let summary): self.formatSummary = summary
                    case .failure(let error): self.message = error.localizedDescription
                    }
                }
            }
        }
    }

    func recordTapped() {
        if isRecording { return stopRecording(because: nil) }
        nameDraft = ""
        asksNameBeforeStart = true
    }

    // Starts recording once the start prompt is answered, by naming the recording or deferring its name.
    func startRecording(named: Bool) {
        userName = named ? enteredName : nil
        isStarting = true
        recorder.startRecording { result in
            self.isStarting = false
            switch result {
            case .success:
                self.isRecording = true
                self.recordingStart = Date()
                UIApplication.shared.isIdleTimerDisabled = true
                self.message = "Recording"
            case .failure(let error):
                self.message = "Cannot record: \(error.localizedDescription)"
            }
        }
    }

    // Stops capture at once, by the Stop button (reason nil) or because capture was cut off; the recording is finished in the background as soon as it has a name, asking for one if it has none yet, and the next recording can start meanwhile.
    func stopRecording(because reason: String?) {
        guard isRecording else { return }
        isRecording = false
        UIApplication.shared.isIdleTimerDisabled = false
        let stopNote = reason.map { "Stopped: \($0)" }
        if let stopNote { message = stopNote }
        // Taken now: the next recording can start, with a name of its own, before this one is handed over.
        let userName = self.userName
        recorder.stopRecording { recording in
            if let userName { return self.finish(recording, userName: userName, stopNote: stopNote) }
            self.unnamed = (recording, stopNote)
            self.nameDraft = ""
            self.asksNameAfterStop = true
        }
    }

    // Finishes the stopped recording once the stop prompt is answered, by naming it or keeping its date and time as its name.
    func nameStopped(named: Bool) {
        guard let (recording, stopNote) = unnamed else { return }
        unnamed = nil
        finish(recording, userName: named ? enteredName : nil, stopNote: stopNote)
    }

    // The name in the prompt's text field; nil when it is blank.
    private var enteredName: String? {
        let name = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    private func finish(_ recording: Recording, userName: String?, stopNote: String?) {
        message = [stopNote, "Saving…"].compactMap { $0 }.joined(separator: ". ")
        recording.finish(userName: userName) { result in
            DispatchQueue.main.async { self.finished(result, note: stopNote) }
        }
    }

    // Adds a finished recording to the gallery and uploads it; a recording with no frames was not kept.
    private func finished(_ result: Result<RecordingInfo?, Error>, note: String?) {
        let outcome: String
        switch result {
        case .success(let info?):
            outcome = "Saved \(info.name)"
            refreshFiles()
            upload(info.id)
        case .success(nil):
            outcome = "Nothing was recorded"
        case .failure(let error):
            outcome = "Saving failed, to be retried at the next launch: \(error.localizedDescription)"
        }
        message = [note, outcome].compactMap { $0 }.joined(separator: ". ")
    }

    // Uploads the recording's members the receiver has not acknowledged, then its manifest; the upload carries on while the app is suspended.
    func upload(_ id: String) {
        guard let file = files.first(where: { $0.id == id }), file.upload.canStart else { return }
        setUpload(id, .inProgress("uploading 0%"))
        Uploader.shared.upload(id, server: server, onProgress: { fraction in
            self.setUpload(id, .inProgress(String(format: "uploading %.0f%%", fraction * 100)))
        }, completion: { result in
            switch result {
            case .success: self.setUpload(id, .uploaded)
            case .failure(let error): self.setUpload(id, .failed(error.localizedDescription))
            }
        })
    }

    // Deletes the recording from this phone only; the copy on the server is kept.
    func delete(_ file: RecordingFile) {
        guard file.canDelete else { return }
        do {
            try FileManager.default.removeItem(at: file.info.directory)
        } catch {
            message = "Delete failed: \(error.localizedDescription)"
        }
        refreshFiles()
    }

    private func setUpload(_ id: String, _ state: UploadState) {
        if let i = files.firstIndex(where: { $0.id == id }) { files[i].upload = state }
    }

    // Lists the recordings, the directories in Documents that hold a recording.json listing their members, newest first, keeping the state of uploads in flight; one from apps 4.1 to 4.5 joins once addMissingMembers has listed its members.
    func refreshFiles() {
        let inFlight = Dictionary(uniqueKeysWithValues: files.map { ($0.id, $0.upload) })
        let urls = (try? FileManager.default.contentsOfDirectory(at: Recording.documents, includingPropertiesForKeys: nil)) ?? []
        var listed: [RecordingFile] = []
        for file in urls.map({ $0.appendingPathComponent(RecordingInfo.fileName) }) where FileManager.default.fileExists(atPath: file.path) && !Recording.listsNoMembers(file) {
            do {
                let info = try RecordingInfo.load(file)
                listed.append(RecordingFile(info: info, upload: inFlight[info.id] ?? (info.uploaded ? .uploaded : .notUploaded)))
            } catch {
                message = "Unreadable \(file.deletingLastPathComponent().lastPathComponent)/\(RecordingInfo.fileName): \(error.localizedDescription)"
            }
        }
        files = listed.sorted { $0.info.startTime > $1.info.startTime }
    }
}
