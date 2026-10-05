import AVFoundation
import CoreMedia
import CoreMotion
import Foundation
import UIKit

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

// Runs the chosen camera's capture source and hands every color frame and every depth frame, each with its own timestamp, to the active recording.
final class Recorder: CaptureSink {
    private let orientation = OrientationTracker()
    let depthPreview = DepthPreview()
    // Starts and stops the sources, one at a time.
    private let controlQueue = DispatchQueue(label: "recorder.control")
    // Every source delivers on this one queue, so a recording sees its frames in arrival order.
    private let dataQueue = DispatchQueue(label: "recorder.data")
    // One source per camera this phone has; made on the main queue, as their previews are views.
    private var sources: [DepthCamera: CaptureSource] = [:]
    // Owned by controlQueue.
    private var running: CaptureSource?

    // Owned by dataQueue.
    private var camera: DepthCamera = .front
    private var format: StreamFormat?
    private var active: Recording?
    private var stats = CaptureStats()
    private var depthDelivered = 0

    var onStats: ((CaptureStats) -> Void)?
    // Called on the main queue with the reason when capture is cut off: the camera was interrupted or failed.
    var onInterruption: ((String) -> Void)?

    init(cameras: [DepthCamera]) {
        for camera in cameras {
            switch camera {
            case .front: sources[camera] = AVFoundationSource(sink: self, queue: dataQueue)
            case .rear: sources[camera] = ARKitSource(sink: self, queue: dataQueue)
            }
        }
    }

    // The view showing the camera's live color stream.
    func preview(for camera: DepthCamera) -> UIView {
        source(camera).preview
    }

    private func source(_ camera: DepthCamera) -> CaptureSource {
        guard let source = sources[camera] else { preconditionFailure("the \(camera.rawValue) camera is not available on this phone") }
        return source
    }

    // Stops the running source and starts the camera's; completion gets a description of the stream format.
    func start(camera: DepthCamera, completion: @escaping (Result<String, Error>) -> Void) {
        let source = source(camera)
        controlQueue.async {
            if let running = self.running, running !== source { running.stop() }
            self.running = source
            // No recording starts until the new source's format is known.
            self.dataQueue.sync { self.format = nil }
            self.orientation.track(device: source.device)
            source.start { result in
                self.dataQueue.async {
                    if case .success(let format) = result {
                        self.camera = camera
                        self.format = format
                        self.stats = CaptureStats()
                    }
                    DispatchQueue.main.async { completion(result.map(\.summary)) }
                }
            }
        }
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

    // Stops the active recording and hands it over to be named and finished.
    func stopRecording(completion: @escaping (Recording) -> Void) {
        dataQueue.async {
            guard let recording = self.active else { return }
            self.active = nil
            self.publishStats()
            DispatchQueue.main.async { completion(recording) }
        }
    }

    func captured(color: CVPixelBuffer, at time: CMTime, intrinsics: matrix_float3x3?, pose: Pose?) {
        guard let active else { return }
        if active.appendColor(color, at: time, intrinsics: intrinsics, pose: pose, orientation: orientation.snapshot()) {
            stats.colorFrames += 1
            if stats.colorFrames % 5 == 0 { publishStats() }
        } else {
            stats.droppedColor += 1
        }
    }

    func droppedColor(at time: CMTime, reason: String) {
        guard let active else { return }
        stats.droppedColor += 1
        active.recordDroppedColor(at: time, reason: reason)
    }

    func captured(depth: DepthSample) {
        depthDelivered += 1
        depthPreview.offer(depth.metres, at: depth.time, uprightRotationDegrees: orientation.snapshot().uprightRotationDegrees, camera: camera)
        if depthDelivered % 15 == 1 {
            (stats.depthValidFraction, stats.depthMedianMeters) = Self.depthSummary(depth.metres)
            if active == nil { publishStats() }
        }
        guard let active else { return }
        stats.depthFrames += 1
        active.appendDepth(depth, orientation: orientation.snapshot())
    }

    func droppedDepth(at time: CMTime, reason: String) {
        guard let active else { return }
        stats.droppedDepth += 1
        active.recordDroppedDepth(at: time, reason: reason)
    }

    func interrupted(_ reason: String) {
        DispatchQueue.main.async { self.onInterruption?(reason) }
    }

    private func publishStats() {
        let snapshot = stats
        DispatchQueue.main.async { self.onStats?(snapshot) }
    }

    // Fraction of pixels with a reading and their median depth in metres, from every 4th pixel of every 4th row of a Float32 metres map.
    private static func depthSummary(_ map: CVPixelBuffer) -> (Double, Double) {
        precondition(CVPixelBufferGetPixelFormatType(map) == kCVPixelFormatType_DepthFloat32, "depth summary of a map that is not Float32 metres")
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
