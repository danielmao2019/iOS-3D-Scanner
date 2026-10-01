import ARKit
import AVFoundation
import UIKit

// The rear LiDAR camera through an ARSession running world tracking with scene depth: each ARFrame carries the color image, the LiDAR depth registered to it, unsmoothed (sceneDepth) or, with the depth filter on, smoothed over time (smoothedSceneDepth) and the depth's confidence, all at the frame's timestamp.
final class ARKitSource: NSObject, CaptureSource, ARSessionDelegate {
    let device: AVCaptureDevice
    var preview: UIView { display }
    private let display = SampleBufferView()
    private let session = ARSession()
    private let videoFormat: ARConfiguration.VideoFormat
    private weak var sink: CaptureSink?
    private let queue: DispatchQueue

    // Owned by queue: the start's ready, until the first frame with scene depth gives the stream format.
    private var pendingReady: ((Result<StreamFormat, Error>) -> Void)?
    // Owned by queue: whether the running session delivers smoothedSceneDepth instead of sceneDepth.
    private var smoothed = false

    // The session delivers its frames on queue.
    init(sink: CaptureSink, queue: DispatchQueue) {
        // The world-tracking video format with the largest captured image, then the highest frame rate, among those with the scene depth map's 4:3 aspect ratio (256×192), since the depth intrinsics are scaled from the color image.
        let formats = ARWorldTrackingConfiguration.supportedVideoFormats.filter { $0.imageResolution.width * 3 == $0.imageResolution.height * 4 }
        guard let videoFormat = formats.max(by: { a, b in
            (a.imageResolution.width * a.imageResolution.height, a.framesPerSecond) < (b.imageResolution.width * b.imageResolution.height, b.framesPerSecond)
        }) else { preconditionFailure("world tracking has no 4:3 video format") }
        guard let device = AVCaptureDevice.default(videoFormat.captureDeviceType, for: .video, position: videoFormat.captureDevicePosition) else {
            preconditionFailure("no capture device for ARKit's \(videoFormat.captureDeviceType.rawValue)")
        }
        self.videoFormat = videoFormat
        self.device = device
        self.sink = sink
        self.queue = queue
        super.init()
        session.delegate = self
        session.delegateQueue = queue
    }

    func start(depthFiltering: Bool, ready: @escaping (Result<StreamFormat, Error>) -> Void) {
        let configuration = ARWorldTrackingConfiguration()
        configuration.videoFormat = videoFormat
        // .smoothedSceneDepth is ARKit's depth smoothed over time, the counterpart of AVFoundation's depth filter.
        configuration.frameSemantics = depthFiltering ? [.smoothedSceneDepth] : [.sceneDepth]
        queue.sync {
            pendingReady = ready
            smoothed = depthFiltering
        }
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
    }

    func stop() {
        session.pause()
        queue.sync { pendingReady = nil }
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let time = CMTime(seconds: frame.timestamp, preferredTimescale: 1_000_000_000)
        let image = frame.capturedImage
        let sceneDepth = smoothed ? frame.smoothedSceneDepth : frame.sceneDepth
        if let ready = pendingReady {
            // The first frames of a session can come before scene depth.
            guard let depth = sceneDepth else { return }
            pendingReady = nil
            ready(streamFormat(image: image, depth: depth))
        }
        display.show(image, at: time)
        let camera = frame.camera
        sink?.captured(color: Self.sampleBuffer(image, at: time), intrinsics: camera.intrinsics)
        guard let depth = sceneDepth else {
            sink?.droppedDepth(at: time, reason: "no_scene_depth")
            return
        }
        let map = depth.depthMap
        let k = camera.intrinsics, resolution = camera.imageResolution
        sink?.captured(depth: DepthSample(
            time: time,
            map: map,
            metres: map,
            confidence: depth.confidenceMap,
            // ARKit's intrinsics are in capturedImage pixels; the depth map covers the same view at a lower resolution.
            intrinsics: scaled(k, scaleX: Float(CVPixelBufferGetWidth(map)) / Float(resolution.width), scaleY: Float(CVPixelBufferGetHeight(map)) / Float(resolution.height)),
            calibration: {
                [
                    "intrinsic_matrix_row_major": [
                        [k.columns.0.x, k.columns.1.x, k.columns.2.x],
                        [k.columns.0.y, k.columns.1.y, k.columns.2.y],
                        [k.columns.0.z, k.columns.1.z, k.columns.2.z],
                    ],
                    "intrinsic_reference_width": Int(resolution.width),
                    "intrinsic_reference_height": Int(resolution.height),
                ]
            },
            filtered: smoothed ? "1" : "0",
            accuracy: "absolute",
            quality: ""))
    }

    func sessionWasInterrupted(_ session: ARSession) {
        sink?.interrupted("the camera was interrupted")
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        sink?.interrupted("the camera failed: \(error.localizedDescription)")
    }

    // The stream format from the first frame with scene depth; the depth intrinsics are scaled from the color image, so the two must have one aspect ratio.
    private func streamFormat(image: CVPixelBuffer, depth: ARDepthData) -> Result<StreamFormat, Error> {
        let colorWidth = CVPixelBufferGetWidth(image), colorHeight = CVPixelBufferGetHeight(image)
        let map = depth.depthMap
        let depthWidth = CVPixelBufferGetWidth(map), depthHeight = CVPixelBufferGetHeight(map)
        guard colorWidth * depthHeight == colorHeight * depthWidth else {
            return .failure(RecorderError("ARKit color \(colorWidth)×\(colorHeight) and depth \(depthWidth)×\(depthHeight) differ in aspect ratio"))
        }
        guard let confidence = depth.confidenceMap else { return .failure(RecorderError("ARKit scene depth came without confidence")) }
        precondition(CVPixelBufferGetWidth(confidence) == depthWidth && CVPixelBufferGetHeight(confidence) == depthHeight, "confidence map differs in size from the depth map")
        precondition(CVPixelBufferGetPixelFormatType(map) == kCVPixelFormatType_DepthFloat32, "scene depth is \(fourCC(CVPixelBufferGetPixelFormatType(map))), not Float32 metres")
        return .success(StreamFormat(
            colorWidth: colorWidth, colorHeight: colorHeight, colorPixelFormat: CVPixelBufferGetPixelFormatType(image),
            depthWidth: depthWidth, depthHeight: depthHeight, depthPixelFormat: CVPixelBufferGetPixelFormatType(map),
            confidencePixelFormat: CVPixelBufferGetPixelFormatType(confidence),
            frameRate: Double(videoFormat.framesPerSecond),
            depthFilteringEnabled: smoothed,
            depthSource: .arkitSceneDepth,
            details: [
                "arkit_frame_semantics": [smoothed ? "smoothedSceneDepth" : "sceneDepth"],
                "arkit_video_format": Self.describe(videoFormat),
                "arkit_video_formats": ARWorldTrackingConfiguration.supportedVideoFormats.map(Self.describe),
            ]))
    }

    private static func describe(_ format: ARConfiguration.VideoFormat) -> String {
        "\(Int(format.imageResolution.width))x\(Int(format.imageResolution.height)) \(format.framesPerSecond) fps \(format.captureDeviceType.rawValue)"
    }

    // The captured image as a sample buffer at the frame's timestamp, for the video writer.
    private static func sampleBuffer(_ image: CVPixelBuffer, at time: CMTime) -> CMSampleBuffer {
        // Both fail only on an image buffer CoreMedia cannot describe, which ARKit's captured images are not.
        try! CMSampleBuffer(imageBuffer: image, formatDescription: CMVideoFormatDescription(imageBuffer: image),
                            sampleTiming: CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: time, decodeTimeStamp: .invalid))
    }

    // Shows ARKit's captured images, turned upright for the portrait-only screen.
    private final class SampleBufferView: UIView {
        private let displayLayer = AVSampleBufferDisplayLayer()

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .black
            displayLayer.videoGravity = .resizeAspect
            layer.addSublayer(displayLayer)
        }

        required init?(coder: NSCoder) { preconditionFailure("not used from a storyboard") }

        // ponytail: a fixed 90° turns the rear camera's landscape images upright on a portrait-only screen; follow the interface orientation if the app ever rotates.
        override func layoutSubviews() {
            super.layoutSubviews()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            displayLayer.setAffineTransform(.identity)
            displayLayer.bounds = CGRect(x: 0, y: 0, width: bounds.height, height: bounds.width)
            displayLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
            displayLayer.setAffineTransform(CGAffineTransform(rotationAngle: .pi / 2))
            CATransaction.commit()
        }

        // Called on the capture queue.
        func show(_ image: CVPixelBuffer, at time: CMTime) {
            let renderer = displayLayer.sampleBufferRenderer
            // The renderer fails when the app goes to the background and needs a flush to show images again.
            if renderer.status == .failed { renderer.flush() }
            let sample = ARKitSource.sampleBuffer(image, at: time)
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true)! as NSArray
            (attachments[0] as! NSMutableDictionary)[kCMSampleAttachmentKey_DisplayImmediately] = true
            renderer.enqueue(sample)
        }
    }
}
