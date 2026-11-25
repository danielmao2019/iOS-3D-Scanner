import AVFoundation
import SwiftUI

@main
struct RGBDScannerApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

// The config selection first, then the scanner, uploading to the config chosen, until it goes back; a computer can take the wired transfer recordings over the cable while the app is on screen.
struct RootView: View {
    @StateObject private var model = AppModel()
    @StateObject private var store = UserStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if model.selection == nil {
                ConfigSelectionView(model: model, store: store)
            } else {
                ContentView(model: model)
            }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in model.serveCable(phase == .active) }
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
    // The receiver has acknowledged every file; the recording leaves the phone once the receiver has stored it.
    case uploaded
    case failed(String)
    // A recording of the This phone config, never uploaded.
    case keptOnPhone
    // A recording of the Wired transfer config, which leaves the phone once a computer has taken it over the cable and stored it.
    case waitingForCable

    var canStart: Bool {
        switch self {
        case .notUploaded, .uploaded, .failed: return true
        case .inProgress, .keptOnPhone, .waitingForCable: return false
        }
    }

    var label: String {
        switch self {
        case .notUploaded: return "not uploaded"
        case .inProgress(let step): return step
        case .uploaded: return "uploaded, checking the server stored it"
        case .failed(let message): return "upload failed: \(message)"
        case .keptOnPhone: return "kept on this phone"
        case .waitingForCable: return "waiting for a computer to take it over the cable"
        }
    }
}

// A finished recording's Documents/<id>/recording.json, beside the recording's files, its members, in that directory, the segments of its frames files in its segments directory from 1.5.0.3; the uploader rewrites it as the receiver acknowledges each member.
struct RecordingInfo: Codable {
    let id: String
    let name: String
    let namedByUser: Bool
    let startTime: Date
    let durationSeconds: Double
    let camera: DepthCamera
    // The key the recording's files upload under: from 1.5.0.3, which uploads its frames while recording, its work directory's name, fixed before its id; nil before, when they upload under the id.
    let uploadId: String?
    // The user who recorded it, nil before 1.5.2, and where it goes, the config chosen when it was recorded, nil before 1.5.0.3.
    let user: String?
    let target: RecordingTarget?
    // The recording's files, in the order the manifest lists them, each frames file's segments in its place.
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
    var uploadKey: String { uploadId ?? id }
    // Whether it stays on this phone: kept there by its config, or with none, as before 1.5.0.3.
    var staysOnPhone: Bool { target == nil || target == .phone }
    // Whether it goes by wired transfer.
    var isWired: Bool { if case .wired? = target { return true } else { return false } }
    // Where a recording's segments are kept from 1.5.0.3 until the receiver acknowledges them.
    var segmentsDirectory: URL? { uploadId.map(Recording.segmentsDirectory) }
    // The file holding a member: a segment's in the segments directory, any other in the recording's directory.
    func url(of member: Member) -> URL {
        guard Recording.isSegment(member.name), let segmentsDirectory else { return directory.appendingPathComponent(member.name) }
        return segmentsDirectory.appendingPathComponent(member.name)
    }
    // The manifest the uploader writes for the receiver once every member is acknowledged; never one of the recording's files.
    var manifest: URL { directory.appendingPathComponent("manifest.json") }

    // The members as the manifest lists them, in recording.json's order with their sizes and SHA-256s, each frames file's consecutive segments grouped under it as {"name", "segments"}.
    var manifestMembers: [[String: Any]] {
        var listed: [[String: Any]] = []
        for member in members {
            let entry: [String: Any] = ["name": member.name, "size": member.size, "sha256": member.sha256]
            guard Recording.isSegment(member.name) else {
                listed.append(entry)
                continue
            }
            // <frames file>.<index, 6 digits>
            let file = String(member.name.dropLast(7))
            if listed.last?["name"] as? String == file, var segments = listed.last?["segments"] as? [[String: Any]] {
                segments.append(entry)
                listed[listed.count - 1]["segments"] = segments
            } else {
                listed.append(["name": file, "segments": [entry]])
            }
        }
        return listed
    }

    // Deletes the recording from the phone, with its segments.
    func removeFromPhone() throws {
        try FileManager.default.removeItem(at: directory)
        if let segmentsDirectory, FileManager.default.fileExists(atPath: segmentsDirectory.path) { try FileManager.default.removeItem(at: segmentsDirectory) }
    }

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
    // Only a recording kept on this phone is deleted by hand; an uploaded one leaves the phone once the receiver has stored it, and its config lists it from the receiver, and a wired transfer one once a computer has stored it.
    var canDelete: Bool { info.staysOnPhone }
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
    // The user and config chosen on the selection page, which new recordings upload to; nil while it shows.
    @Published var selection: Selection?
    // For a server config, the recordings its receiver holds in the data root, as it last listed them.
    @Published var serverRecordings: [ServerRecording] = []
    // The recordings on this phone the scanner lists: those made with the chosen config, by any user, as configs such as This phone are shared, This phone's also those with no config, and Wired transfer's those made with any folder.
    var shownFiles: [RecordingFile] {
        files.filter {
            switch selection?.target {
            case .phone?: return $0.info.staysOnPhone
            case .wired?: return $0.info.isWired
            default: return $0.info.target == selection?.target
            }
        }
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

    struct Selection: Equatable {
        let user: String
        let target: RecordingTarget
    }

    let availableCameras: [DepthCamera]
    let recorder: Recorder
    private let cable = WiredServer()
    // The cable's requests open, and when the last one ended: a computer is taking recordings while one is open or one ended within cableQuietSeconds, and the screen stays awake meanwhile.
    private var cableRequests = 0
    private var cableLastRequest = Date.distantPast
    private static let cableQuietSeconds = 10.0
    // The name given when the recording started; nil when naming was deferred.
    private var userName: String?
    // A stopped recording waiting for its name, with why it stopped when it was not the Stop button.
    private var unnamed: (recording: Recording, stopNote: String?)?

    init() {
        availableCameras = DepthCamera.allCases.filter(\.isAvailable)
        recorder = Recorder(cameras: availableCameras)
        if let first = availableCameras.first { camera = first }
        recorder.onStats = { [weak self] in self?.stats = $0 }
        recorder.depthPreview.onFrame = { [weak self] frame in
            guard let self, self.showsDepth else { return }
            self.depthFrame = frame
        }
        recorder.onInterruption = { [weak self] reason in self?.stopRecording(because: reason) }
        cable.onRequest = { [weak self] id, began in self?.cableRequest(for: id, began: began) }
        cable.onStored = { [weak self] info in
            self?.message = "\(info.name) is stored on the computer and has left this phone"
            self?.refreshFiles()
        }
        refreshFiles()
        // A recording uploading resumes, the members the receiver acknowledged and those still on their way not sent again, and one uploaded leaves the phone once the receiver has stored it.
        files.filter { if case .upload = $0.info.target { return true } else { return false } }.forEach { upload($0.id) }
        recoverLeftovers()
        addMissingMembers()
    }

    // Lists the members of the recordings apps 1.4.1 to 1.4.5 finished, which the gallery shows once they have them; one not yet uploaded then uploads.
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

    // Lets a computer take the wired transfer recordings over the cable while the app is on screen, iOS suspending the app, and with it the cable, when it leaves the screen.
    func serveCable(_ serving: Bool) {
        guard serving else { return cable.stop() }
        do {
            try cable.start()
        } catch {
            message = "Wired transfer unavailable: \(error.localizedDescription)"
        }
    }

    // Shows a wired transfer recording as being taken while a request for it is open, and keeps the screen awake while a computer is taking recordings.
    private func cableRequest(for id: String?, began: Bool) {
        cableRequests += began ? 1 : -1
        cableLastRequest = Date()
        if let id, files.first(where: { $0.id == id })?.info.isWired == true { setUpload(id, began ? .inProgress("being taken over the cable") : .waitingForCable) }
        updateIdleTimer()
        if !began { DispatchQueue.main.asyncAfter(deadline: .now() + Self.cableQuietSeconds) { self.updateIdleTimer() } }
    }

    // The screen stays awake while recording and while a computer is taking recordings over the cable, which would stop if the screen locked.
    private func updateIdleTimer() {
        let cableActive = cableRequests > 0 || Date().timeIntervalSince(cableLastRequest) < Self.cableQuietSeconds
        UIApplication.shared.isIdleTimerDisabled = isRecording || cableActive
    }

    // Opens the scanner, its recordings going where the user's config says.
    func select(user: String, target: RecordingTarget) {
        selection = Selection(user: user, target: target)
        serverRecordings = []
        refreshServerRecordings()
    }

    // Asks the chosen server config's receiver which recordings its data root holds; This phone has none.
    func refreshServerRecordings() {
        guard let selection, case .upload(let destination) = selection.target else { return }
        Uploader.shared.listRecordings(on: destination) { result in
            // The config may have changed while the receiver answered.
            guard self.selection == selection else { return }
            switch result {
            case .success(let recordings): self.serverRecordings = recordings
            case .failure(let error): self.message = "Cannot list \(destination.server) \(destination.dataRoot): \(error.localizedDescription)"
            }
        }
    }

    // Goes back to the selection page, closing the camera; not while recording.
    func leaveScanner() {
        guard !isRecording && !isStarting else { return }
        recorder.stop()
        formatSummary = ""
        selection = nil
        serverRecordings = []
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
        guard let selection else { preconditionFailure("recording with no config chosen") }
        userName = named ? enteredName : nil
        isStarting = true
        // Uploading, each segment goes up as soon as the recording closes it; by wired transfer, a computer can take it over the cable as soon as it is closed; kept on the phone, it stays.
        let cable = self.cable
        recorder.startRecording(user: selection.user, target: selection.target, onSegment: { segment in
            switch selection.target {
            case .upload(let destination): DispatchQueue.main.async { Uploader.shared.uploadSegment(segment, to: destination) }
            case .wired(let path): cable.add(segment, path: path)
            case .phone: break
            }
        }) { result in
            self.isStarting = false
            switch result {
            case .success:
                self.isRecording = true
                self.recordingStart = Date()
                self.updateIdleTimer()
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
        updateIdleTimer()
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
    var enteredName: String? {
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
            if case .upload = info.target { upload(info.id) }
        case .success(nil):
            outcome = "Nothing was recorded"
        case .failure(let error):
            outcome = "Saving failed, to be retried at the next launch: \(error.localizedDescription)"
        }
        message = [note, outcome].compactMap { $0 }.joined(separator: ". ")
    }

    // Uploads the recording's members the receiver has not acknowledged, then its manifest, and deletes the recording once the receiver has stored it; the upload carries on while the app is suspended.
    func upload(_ id: String) {
        guard let file = files.first(where: { $0.id == id }), file.upload.canStart else { return }
        setUpload(id, .inProgress("uploading 0%"))
        Uploader.shared.upload(id, onProgress: { fraction in
            self.setUpload(id, .inProgress(String(format: "uploading %.0f%%", fraction * 100)))
        }, completion: { result in
            switch result {
            // The recording has left the phone, and the receiver lists it.
            case .success:
                self.refreshFiles()
                self.refreshServerRecordings()
            case .failure(let error): self.setUpload(id, .failed(error.localizedDescription))
            }
        })
    }

    // Deletes a recording kept on this phone, with its segments.
    func delete(_ file: RecordingFile) {
        guard file.canDelete else { return }
        do {
            try file.info.removeFromPhone()
        } catch {
            message = "Delete failed: \(error.localizedDescription)"
        }
        refreshFiles()
    }

    private func setUpload(_ id: String, _ state: UploadState) {
        if let i = files.firstIndex(where: { $0.id == id }) { files[i].upload = state }
    }

    // Lists the recordings, the directories in Documents that hold a recording.json listing their members, newest first, keeping the state of uploads in flight; one from apps 1.4.1 to 1.4.5 joins once addMissingMembers has listed its members.
    func refreshFiles() {
        let inFlight = Dictionary(uniqueKeysWithValues: files.map { ($0.id, $0.upload) })
        let urls = (try? FileManager.default.contentsOfDirectory(at: Recording.documents, includingPropertiesForKeys: nil)) ?? []
        var listed: [RecordingFile] = []
        for file in urls.map({ $0.appendingPathComponent(RecordingInfo.fileName) }) where FileManager.default.fileExists(atPath: file.path) && !Recording.listsNoMembers(file) {
            do {
                let info = try RecordingInfo.load(file)
                let state: UploadState = info.staysOnPhone ? .keptOnPhone : info.isWired ? .waitingForCable : info.uploaded ? .uploaded : .notUploaded
                listed.append(RecordingFile(info: info, upload: inFlight[info.id] ?? state))
            } catch {
                message = "Unreadable \(file.deletingLastPathComponent().lastPathComponent)/\(RecordingInfo.fileName): \(error.localizedDescription)"
            }
        }
        files = listed.sorted { $0.info.startTime > $1.info.startTime }
    }
}
