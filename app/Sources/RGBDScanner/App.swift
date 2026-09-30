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

// A finished recording in Documents.
struct RecordingFile: Identifiable {
    let url: URL
    var id: String { url.lastPathComponent }
    let size: Int64
    var upload: UploadState
}

final class AppModel: ObservableObject {
    @Published var camera: DepthCamera = .front
    @Published var formatSummary = ""
    @Published var stats = CaptureStats()
    @Published var isRecording = false
    @Published var isFinishing = false
    @Published var recordingStart = Date()
    @Published var message = ""
    @Published var files: [RecordingFile] = []
    @Published var server: String {
        didSet { UserDefaults.standard.set(server, forKey: "server") }
    }

    let availableCameras = DepthCamera.allCases.filter { $0.device != nil }
    let recorder = Recorder()
    private let uploader = Uploader()

    init() {
        server = UserDefaults.standard.string(forKey: "server") ?? Secrets.server
        if let first = availableCameras.first { camera = first }
        recorder.onStats = { [weak self] in self?.stats = $0 }
        refreshFiles()
        // A recording left un-uploaded, e.g. by closing the app mid-upload, goes up now.
        files.filter { $0.upload == .notUploaded }.forEach { upload($0.url) }
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

    func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        recorder.startRecording { result in
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

    // Stops, packages, and uploads the new recording.
    private func stopRecording() {
        isRecording = false
        isFinishing = true
        UIApplication.shared.isIdleTimerDisabled = false
        message = "Packaging…"
        recorder.stopRecording { result in
            self.isFinishing = false
            switch result {
            case .success(let tar):
                self.message = "Saved \(tar.lastPathComponent)"
                self.refreshFiles()
                self.upload(tar)
            case .failure(let error):
                self.message = "Recording failed: \(error.localizedDescription)"
            }
        }
    }

    func upload(_ url: URL) {
        guard let file = files.first(where: { $0.url == url }), file.upload.canStart else { return }
        setUpload(url, .inProgress("hashing…"))
        uploader.upload(file: url, server: server, onProgress: { fraction in
            self.setUpload(url, .inProgress(String(format: "uploading %.0f%%", fraction * 100)))
        }, completion: { result in
            switch result {
            case .success: self.setUpload(url, .uploaded)
            case .failure(let error): self.setUpload(url, .failed(error.localizedDescription))
            }
        })
    }

    func delete(_ file: RecordingFile) {
        guard file.upload.canStart || file.upload == .uploaded else { return }
        try? FileManager.default.removeItem(at: file.url)
        UserDefaults.standard.removeObject(forKey: Self.uploadedKey(file.url))
        refreshFiles()
    }

    private func setUpload(_ url: URL, _ state: UploadState) {
        if let i = files.firstIndex(where: { $0.url == url }) { files[i].upload = state }
        UserDefaults.standard.set(state == .uploaded, forKey: Self.uploadedKey(url))
    }

    private static func uploadedKey(_ url: URL) -> String { "uploaded." + url.lastPathComponent }

    // Lists Documents/*.tar, keeping the state of uploads in flight.
    func refreshFiles() {
        let inFlight = Dictionary(uniqueKeysWithValues: files.map { ($0.url, $0.upload) })
        let urls = (try? FileManager.default.contentsOfDirectory(at: Recording.documents, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        files = urls.filter { $0.pathExtension == "tar" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .map { url in
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 } ?? 0
                let stored: UploadState = UserDefaults.standard.bool(forKey: Self.uploadedKey(url)) ? .uploaded : .notUploaded
                return RecordingFile(url: url, size: Int64(size), upload: inFlight[url] ?? stored)
            }
    }
}
