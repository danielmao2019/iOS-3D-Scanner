import AVFoundation
import CoreMedia
import CoreMotion
import Foundation

// What the screen shows about the stream: depth coverage all the time, frame counts while recording.
struct CaptureStats {
    var colorFrames = 0
    var depthFrames = 0
    var droppedColor = 0
    var droppedDepth = 0
    var depthValidFraction: Double = 0
    var depthMedianMeters: Double = 0
}

// How the phone was held at a moment, as recorded with each frame.
struct Orientation {
    // Clockwise rotation, in degrees, that turns a sensor-oriented frame upright (horizon-level).
    var uprightRotationDegrees = 0
    // Gravity in g, in the phone's device frame (x right, y toward the top of the phone held in portrait, z out of the screen).
    var gravity: SIMD3<Double>?
    // When the gravity sample was taken, in seconds on the frames' clock.
    var gravityTime: Double?
}

// Follows how the phone is held, from the capture device's rotation coordinator and the motion sensors.
final class OrientationTracker {
    private let lock = NSLock()
    private var current = Orientation()
    private var coordinator: AVCaptureDevice.RotationCoordinator?
    private var observation: NSKeyValueObservation?
    private let motion = CMMotionManager()
    private let motionQueue = OperationQueue()

    func track(device: AVCaptureDevice) {
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
        observation = coordinator.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.initial, .new]) { [weak self] c, _ in
            self?.update { $0.uprightRotationDegrees = Int(c.videoRotationAngleForHorizonLevelCapture.rounded()) }
        }
        self.coordinator = coordinator

        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 100
        motion.startDeviceMotionUpdates(to: motionQueue) { [weak self] data, _ in
            guard let data else { return }
            self?.update {
                $0.gravity = SIMD3(data.gravity.x, data.gravity.y, data.gravity.z)
                $0.gravityTime = data.timestamp
            }
        }
    }

    func snapshot() -> Orientation {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    private func update(_ change: (inout Orientation) -> Void) {
        lock.lock()
        change(&current)
        lock.unlock()
    }
}

// Runs the capture session and hands every color frame and every depth frame, each with its own timestamp, to the active recording.
final class Recorder: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureDepthDataOutputDelegate {
    let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let depthOutput = AVCaptureDepthDataOutput()
    private let orientation = OrientationTracker()
    let depthPreview = DepthPreview()
    private let sessionQueue = DispatchQueue(label: "recorder.session")
    // Both outputs deliver on this one queue, so a recording sees its frames in arrival order.
    private let dataQueue = DispatchQueue(label: "recorder.data")

    // Owned by dataQueue.
    private var camera: DepthCamera = .front
    private var format: CaptureFormat?
    private var active: Recording?
    private var stats = CaptureStats()
    private var depthDelivered = 0

    var onStats: ((CaptureStats) -> Void)?
    // Called on the main queue with the reason when capture is cut off: the session was interrupted or failed.
    var onInterruption: ((String) -> Void)?

    override init() {
        super.init()
        NotificationCenter.default.addObserver(forName: .AVCaptureSessionWasInterrupted, object: session, queue: .main) { [weak self] notification in
            let reason = (notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int).flatMap(AVCaptureSession.InterruptionReason.init(rawValue:))
            self?.onInterruption?(Self.describe(reason))
        }
        NotificationCenter.default.addObserver(forName: .AVCaptureSessionRuntimeError, object: session, queue: .main) { [weak self] notification in
            let error = notification.userInfo?[AVCaptureSessionErrorKey] as? Error
            self?.onInterruption?("the camera failed: \(error?.localizedDescription ?? "unknown error")")
        }
    }

    // Configures the session for a camera and (re)starts it; returns a description of the chosen formats.
    func start(camera: DepthCamera, completion: @escaping (Result<String, Error>) -> Void) {
        sessionQueue.async {
            do {
                // Intrinsic matrix delivery can be enabled only while the session is stopped.
                if self.session.isRunning { self.session.stopRunning() }
                let format = try self.configure(camera: camera)
                self.session.startRunning()
                self.dataQueue.sync {
                    self.camera = camera
                    self.format = format
                    self.stats = CaptureStats()
                }
                let color = format.colorDimensions, depth = format.depthDimensions
                let summary = "color \(color.width)×\(color.height) · depth \(depth.width)×\(depth.height) \(fourCC(format.depthPixelFormat)) · \(String(format: "%.0f", format.frameRate)) fps"
                DispatchQueue.main.async { completion(.success(summary)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    private func configure(camera: DepthCamera) throws -> CaptureFormat {
        guard let device = camera.device else { throw RecorderError("\(camera.label) is not available on this phone") }
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }
        session.sessionPreset = .inputPriority

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw RecorderError("cannot add camera input") }
        session.addInput(input)

        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        videoOutput.alwaysDiscardsLateVideoFrames = false
        videoOutput.setSampleBufferDelegate(self, queue: dataQueue)
        guard session.canAddOutput(videoOutput) else { throw RecorderError("cannot add video output") }
        session.addOutput(videoOutput)

        // Raw sensor depth: Apple's filter smooths the stream over time and interpolates missing values.
        depthOutput.isFilteringEnabled = false
        depthOutput.alwaysDiscardsLateDepthData = false
        depthOutput.setDelegate(self, callbackQueue: dataQueue)
        guard session.canAddOutput(depthOutput) else { throw RecorderError("cannot add depth output") }
        session.addOutput(depthOutput)

        // Depth formats can be chosen only once the depth output is attached.
        guard let format = CaptureFormat.best(for: device) else { throw RecorderError("no format with depth") }
        try device.lockForConfiguration()
        device.activeFormat = format.color
        device.activeDepthDataFormat = format.depth
        device.activeVideoMinFrameDuration = format.frameDuration
        device.activeVideoMaxFrameDuration = format.frameDuration
        device.activeDepthDataMinFrameDuration = format.frameDuration
        device.unlockForConfiguration()

        // Frames are kept in the sensor's own orientation and unmirrored, the orientation Apple's calibration describes; how the phone was held is recorded with each frame instead.
        for connection in [videoOutput.connection(with: .video), depthOutput.connection(with: .depthData)].compactMap({ $0 }) {
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = false
            }
        }
        if let video = videoOutput.connection(with: .video), video.isCameraIntrinsicMatrixDeliverySupported {
            video.isCameraIntrinsicMatrixDeliveryEnabled = true
        }
        orientation.track(device: device)
        return format
    }

    // Starts writing frames to a new recording.
    func startRecording(completion: @escaping (Result<Void, Error>) -> Void) {
        dataQueue.async {
            do {
                guard let format = self.format else { throw RecorderError("camera not ready") }
                guard self.active == nil else { throw RecorderError("already recording") }
                self.active = try Recording(camera: self.camera, format: format)
                (self.stats.colorFrames, self.stats.depthFrames, self.stats.droppedColor, self.stats.droppedDepth) = (0, 0, 0, 0)
                self.publishStats()
                DispatchQueue.main.async { completion(.success(())) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    // Stops the active recording and hands it over to be named and packed.
    func stopRecording(completion: @escaping (Recording) -> Void) {
        dataQueue.async {
            guard let recording = self.active else { return }
            self.active = nil
            self.publishStats()
            recording.stop()
            DispatchQueue.main.async { completion(recording) }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let active else { return }
        if active.appendColor(sampleBuffer, orientation: orientation.snapshot()) {
            stats.colorFrames += 1
            if stats.colorFrames % 5 == 0 { publishStats() }
        } else {
            stats.droppedColor += 1
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let active else { return }
        stats.droppedColor += 1
        active.recordDroppedColor(at: CMSampleBufferGetPresentationTimeStamp(sampleBuffer), reason: "dropped")
    }

    func depthDataOutput(_ output: AVCaptureDepthDataOutput, didOutput depthData: AVDepthData, timestamp: CMTime, connection: AVCaptureConnection) {
        depthDelivered += 1
        depthPreview.offer(depthData, at: timestamp, uprightRotationDegrees: orientation.snapshot().uprightRotationDegrees, camera: camera)
        if depthDelivered % 15 == 1 {
            (stats.depthValidFraction, stats.depthMedianMeters) = Self.depthSummary(depthData)
            if active == nil { publishStats() }
        }
        guard let active else { return }
        stats.depthFrames += 1
        active.appendDepth(depthData, at: timestamp, orientation: orientation.snapshot())
    }

    func depthDataOutput(_ output: AVCaptureDepthDataOutput, didDrop depthData: AVDepthData, timestamp: CMTime, connection: AVCaptureConnection, reason: AVCaptureOutput.DataDroppedReason) {
        guard let active else { return }
        stats.droppedDepth += 1
        active.recordDroppedDepth(at: timestamp, reason: Recording.describe(reason))
    }

    private static func describe(_ reason: AVCaptureSession.InterruptionReason?) -> String {
        switch reason {
        case .videoDeviceNotAvailableInBackground: return "the app went to the background"
        case .videoDeviceInUseByAnotherClient: return "another app took the camera"
        case .videoDeviceNotAvailableWithMultipleForegroundApps: return "the camera is unavailable with several apps on screen"
        case .videoDeviceNotAvailableDueToSystemPressure: return "the phone is under too much load or too hot"
        default: return "the camera was interrupted"
        }
    }

    private func publishStats() {
        let snapshot = stats
        DispatchQueue.main.async { self.onStats?(snapshot) }
    }

    // Fraction of pixels with a reading and their median depth in metres, from every 4th pixel of every 4th row.
    private static func depthSummary(_ depthData: AVDepthData) -> (Double, Double) {
        let map = depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32).depthDataMap
        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        let width = CVPixelBufferGetWidth(map), height = CVPixelBufferGetHeight(map)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(map)
        guard let base = CVPixelBufferGetBaseAddress(map) else { return (0, 0) }
        var valid: [Float] = []
        var total = 0
        for y in stride(from: 0, to: height, by: 4) {
            let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: Float32.self)
            for x in stride(from: 0, to: width, by: 4) {
                total += 1
                if row[x].isFinite && row[x] > 0 { valid.append(row[x]) }
            }
        }
        guard !valid.isEmpty else { return (0, 0) }
        valid.sort()
        return (Double(valid.count) / Double(total), Double(valid[valid.count / 2]))
    }
}
