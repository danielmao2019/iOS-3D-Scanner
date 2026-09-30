import AVFoundation
import SwiftUI

@main
struct RGBDScannerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
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

// A finished recording's sidecar, Documents/<id>.json, next to its Documents/<id>.tar.
struct RecordingInfo: Codable {
    let id: String
    let name: String
    let namedByUser: Bool
    let startTime: Date
    let durationSeconds: Double
    let camera: DepthCamera
    var uploaded: Bool
    // Set when the color video's writer failed; the depth stream and tables are complete regardless.
    let colorVideoError: String?

    var tar: URL { Recording.documents.appendingPathComponent("\(id).tar") }
    var sidecar: URL { Recording.documents.appendingPathComponent("\(id).json") }

    func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    static func load(_ sidecar: URL) throws -> RecordingInfo {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(RecordingInfo.self, from: Data(contentsOf: sidecar))
    }
}

// A gallery entry: a finished recording with its size and where its upload stands.
struct RecordingFile: Identifiable {
    var info: RecordingInfo
    let size: Int64
    var upload: UploadState
    var id: String { info.id }
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
    // From Stop until the recording is packed, which waits for its name.
    @Published var isFinishing = false
    @Published var recordingStart = Date()
    @Published var message = ""
    @Published var files: [RecordingFile] = []
    @Published var server: String {
        didSet { UserDefaults.standard.set(server, forKey: "server") }
    }
    @Published var showsDepth = false {
        didSet {
            recorder.depthPreview.isEnabled = showsDepth
            if !showsDepth { depthImage = nil }
        }
    }
    @Published var depthImage: UIImage?
    @Published var asksNameBeforeStart = false
    @Published var asksNameAfterStop = false
    @Published var nameDraft = ""

    let availableCameras = DepthCamera.allCases.filter { $0.device != nil }
    let recorder = Recorder()
    private let uploader = Uploader()
    // The name given when the recording started; nil when naming was deferred.
    private var userName: String?
    // A stopped recording waiting for its name, with why it stopped when it was not the Stop button.
    private var unnamed: (recording: Recording, stopNote: String?)?

    init() {
        server = UserDefaults.standard.string(forKey: "server") ?? Secrets.server
        if let first = availableCameras.first { camera = first }
        recorder.onStats = { [weak self] in self?.stats = $0 }
        recorder.depthPreview.onImage = { [weak self] image in
            guard let self, self.showsDepth else { return }
            self.depthImage = image
        }
        recorder.onInterruption = { [weak self] reason in self?.stopRecording(because: reason) }
        refreshFiles()
        // A recording left un-uploaded, e.g. by closing the app mid-upload, goes up now.
        files.filter { !$0.info.uploaded }.forEach { upload($0.id) }
        recoverLeftovers()
    }

    // Packs, under their date and time, the recordings a closed app or a failed pack left unpacked.
    private func recoverLeftovers() {
        let directories = Recording.leftovers()
        DispatchQueue.global(qos: .utility).async {
            for directory in directories {
                let result = Result { try Recording.pack(directory, userName: nil, colorVideoError: nil, recovered: true) }
                DispatchQueue.main.async { self.packed(result, note: "Recovered an unfinished recording") }
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

    // Stops capture at once, by the Stop button (reason nil) or because capture was cut off; the recording is packed as soon as it has a name, asking for one if it has none yet.
    func stopRecording(because reason: String?) {
        guard isRecording else { return }
        isRecording = false
        isFinishing = true
        UIApplication.shared.isIdleTimerDisabled = false
        let stopNote = reason.map { "Stopped: \($0)" }
        if let stopNote { message = stopNote }
        recorder.stopRecording { recording in
            if let userName = self.userName { return self.pack(recording, userName: userName, stopNote: stopNote) }
            self.unnamed = (recording, stopNote)
            self.nameDraft = ""
            self.asksNameAfterStop = true
        }
    }

    // Packs the stopped recording once the stop prompt is answered, by naming it or keeping its date and time as its name.
    func nameStopped(named: Bool) {
        guard let (recording, stopNote) = unnamed else { return }
        unnamed = nil
        pack(recording, userName: named ? enteredName : nil, stopNote: stopNote)
    }

    // The name in the prompt's text field; nil when it is blank.
    private var enteredName: String? {
        let name = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    private func pack(_ recording: Recording, userName: String?, stopNote: String?) {
        message = [stopNote, "Packaging…"].compactMap { $0 }.joined(separator: ". ")
        recording.pack(userName: userName) { result in
            DispatchQueue.main.async {
                self.isFinishing = false
                self.packed(result, note: stopNote)
            }
        }
    }

    // Adds a packed recording to the gallery and uploads it; a recording with no frames was not packed.
    private func packed(_ result: Result<RecordingInfo?, Error>, note: String?) {
        let outcome: String
        switch result {
        case .success(let info?):
            outcome = info.colorVideoError.map { "Saved \(info.name), but its color video failed: \($0)" } ?? "Saved \(info.name)"
            refreshFiles()
            upload(info.id)
        case .success(nil):
            outcome = "Nothing was recorded"
        case .failure(let error):
            outcome = "Packing failed, to be retried at the next launch: \(error.localizedDescription)"
        }
        message = [note, outcome].compactMap { $0 }.joined(separator: ". ")
    }

    func upload(_ id: String) {
        guard let file = files.first(where: { $0.id == id }), file.upload.canStart else { return }
        setUpload(id, .inProgress("hashing…"))
        uploader.upload(file: file.info.tar, server: server, onProgress: { fraction in
            self.setUpload(id, .inProgress(String(format: "uploading %.0f%%", fraction * 100)))
        }, completion: { result in
            switch result {
            case .success: self.markUploaded(id)
            case .failure(let error): self.setUpload(id, .failed(error.localizedDescription))
            }
        })
    }

    // Deletes the recording from this phone only; the copy on the server is kept.
    func delete(_ file: RecordingFile) {
        guard file.canDelete else { return }
        do {
            try FileManager.default.removeItem(at: file.info.tar)
            try FileManager.default.removeItem(at: file.info.sidecar)
        } catch {
            message = "Delete failed: \(error.localizedDescription)"
        }
        refreshFiles()
    }

    private func setUpload(_ id: String, _ state: UploadState) {
        if let i = files.firstIndex(where: { $0.id == id }) { files[i].upload = state }
    }

    private func markUploaded(_ id: String) {
        setUpload(id, .uploaded)
        guard let i = files.firstIndex(where: { $0.id == id }) else { return }
        files[i].info.uploaded = true
        do { try files[i].info.write(to: files[i].info.sidecar) } catch { message = "Cannot record the upload of \(files[i].info.name): \(error.localizedDescription)" }
    }

    // Lists the recordings that have a sidecar and a .tar in Documents, newest first, keeping the state of uploads in flight.
    func refreshFiles() {
        let inFlight = Dictionary(uniqueKeysWithValues: files.map { ($0.id, $0.upload) })
        let urls = (try? FileManager.default.contentsOfDirectory(at: Recording.documents, includingPropertiesForKeys: nil)) ?? []
        var listed: [RecordingFile] = []
        for sidecar in urls where sidecar.pathExtension == "json" {
            do {
                let info = try RecordingInfo.load(sidecar)
                // The .tar can be removed through the Files app, which shows Documents.
                guard let size = try? info.tar.resourceValues(forKeys: [.fileSizeKey]).fileSize else { continue }
                listed.append(RecordingFile(info: info, size: Int64(size), upload: inFlight[info.id] ?? (info.uploaded ? .uploaded : .notUploaded)))
            } catch {
                message = "Unreadable \(sidecar.lastPathComponent): \(error.localizedDescription)"
            }
        }
        files = listed.sorted { $0.info.startTime > $1.info.startTime }
    }
}
