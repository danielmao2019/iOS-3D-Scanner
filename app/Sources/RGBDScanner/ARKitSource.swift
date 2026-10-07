import ARKit
import AVFoundation
import UIKit

// The rear LiDAR camera through an ARSession running world tracking with scene depth and autofocus: each ARFrame carries the color image, the camera's pose, the LiDAR depth registered to the image, unsmoothed (sceneDepth), and the depth's confidence, all at the frame's timestamp.
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

    // The session delivers its frames on queue.
    init(sink: CaptureSink, queue: DispatchQueue) {
        // The world-tracking video format with the largest captured image, then the highest frame rate, among those with the scene depth map's 4:3 aspect ratio (256×192), since the depth intrinsics are carried over from the color image.
        let formats = ARWorldTrackingConfiguration.supportedVideoFormats.filter { $0.imageResolution.width * 3 == $0.imageResolution.height * 4 }
        guard let videoFormat = formats.max(by: { a, b in
            (a.imageResolution.width * a.imageResolution.height, a.framesPerSecond) < (b.imageResolution.width * b.imageResolution.height, b.framesPerSecond)
        }) else { preconditionFailure("world tracking has no 4:3 video format") }
        // The camera ARKit captures through, whose lens position each color frame records.
        guard let device = ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera else { preconditionFailure("world tracking names no primary camera") }
        precondition(device.deviceType == videoFormat.captureDeviceType && device.position == videoFormat.captureDevicePosition,
                     "ARKit's primary camera \(device.deviceType.rawValue) is not its video format's \(videoFormat.captureDeviceType.rawValue)")
        self.videoFormat = videoFormat
        self.device = device
        self.sink = sink
        self.queue = queue
        super.init()
        session.delegate = self
        session.delegateQueue = queue
    }

    func start(ready: @escaping (Result<StreamFormat, Error>) -> Void) {
        let configuration = ARWorldTrackingConfiguration()
        configuration.videoFormat = videoFormat
        // Unsmoothed depth: .smoothedSceneDepth would average it over time.
        configuration.frameSemantics = [.sceneDepth]
        configuration.isAutoFocusEnabled = true
        queue.sync { pendingReady = ready }
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
    }

    func stop() {
        session.pause()
        queue.sync { pendingReady = nil }
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let received = CMClockGetTime(CMClockGetHostTimeClock())
        let time = CMTime(seconds: frame.timestamp, preferredTimescale: 1_000_000_000)
        let image = frame.capturedImage
        if let ready = pendingReady {
            // The first frames of a session can come before scene depth.
            guard let depth = frame.sceneDepth else { return }
            pendingReady = nil
            ready(streamFormat(image: image, depth: depth))
        }
        display.show(image, at: time)
        let camera = frame.camera
        sink?.captured(color: ColorSample(
            time: time,
            image: image,
            intrinsics: camera.intrinsics,
            exposureDuration: camera.exposureDuration,
            lensPosition: device.lensPosition,
            received: received,
            pose: Pose(trackingState: Self.describe(camera.trackingState), worldFromCamera: camera.transform)))
        guard let depth = frame.sceneDepth else {
            sink?.droppedDepth(at: time, reason: "no_scene_depth")
            return
        }
        let map = depth.depthMap
        let resolution = camera.imageResolution
        sink?.captured(depth: DepthSample(
            time: time,
            map: map,
            metres: map,
            confidence: depth.confidenceMap,
            // ARKit's intrinsics are in capturedImage pixels, measured from the center of the upper-left pixel; the depth map covers the same view at a lower resolution, its grid laid on the image as arkitDepthIntrinsics describes.
            intrinsics: arkitDepthIntrinsics(camera.intrinsics, scaleX: Float(CVPixelBufferGetWidth(map)) / Float(resolution.width), scaleY: Float(CVPixelBufferGetHeight(map)) / Float(resolution.height)),
            sourceCells: [],
            calibration: nil))
    }

    func sessionWasInterrupted(_ session: ARSession) {
        sink?.interrupted("the camera was interrupted")
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        sink?.interrupted("the camera failed: \(error.localizedDescription)")
    }

    // The color.csv cell of a tracking state: normal, not_available or limited_<reason>.
    private static func describe(_ state: ARCamera.TrackingState) -> String {
        switch state {
        case .normal: return "normal"
        case .notAvailable: return "not_available"
        case .limited(let reason):
            switch reason {
            case .initializing: return "limited_initializing"
            case .excessiveMotion: return "limited_excessive_motion"
            case .insufficientFeatures: return "limited_insufficient_features"
            case .relocalizing: return "limited_relocalizing"
            @unknown default: preconditionFailure("tracking is limited for a reason this app does not know: \(reason)")
            }
        }
    }

    // The stream format from the first frame with scene depth; the depth intrinsics are carried over from the color image, so the two must have one aspect ratio.
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
            colorWidth: colorWidth, colorHeight: colorHeight, colorYCbCrMatrix: ycbcrMatrix(image),
            depthWidth: depthWidth, depthHeight: depthHeight, depthPixelFormat: CVPixelBufferGetPixelFormatType(map),
            confidencePixelFormat: CVPixelBufferGetPixelFormatType(confidence),
            frameRate: Double(videoFormat.framesPerSecond),
            details: [
                "focus": "autofocus",
                "intrinsics_convention": "color.csv's fx,fy,cx,cy are each frame's ARCamera.intrinsics, in color pixels, the principal point measured, as ARCamera.h says, from the center of the upper-left pixel; depth.csv's carry them to the depth map, which covers the same view at a lower resolution, as its grid lies on the color image, which six rear scans (2026-09-30 to 2026-10-02) measured from where depth edges land on color edges, x and y differing: along x the depth grid's first column center sits on the color image's first column center, along y the depth rows span the color image's rows edge to edge, so with sx = depth_width / color_width and sy = depth_height / color_height, fx_d = fx * sx, fy_d = fy * sy, cx_d = cx * sx, cy_d = (cy + 0.5) * sy - 0.5",
                "pose_convention": "color.csv's world_from_camera_<row><column> are rows 0-2 of ARCamera.transform, row-major (the constant bottom row 0,0,0,1 omitted): the transform from ARKit's camera frame to its world frame, in metres; the camera frame, as Apple defines it, has its origin at the camera, +x toward increasing column of the sensor-oriented color image, +y toward decreasing row, +z out of the lens toward the viewer, the camera looking along -z; the world frame is gravity-aligned with +y up, its origin and heading where tracking started, and each session start resets tracking; the poses are ARKit's estimates, and tracking_state says under which tracking state each was made",
                "exposure_lens_arrival_convention": "color.csv's exposure_duration_s is each delivered frame's own exposure time in seconds, its ARFrame.camera.exposureDuration; lens_position is the lensPosition (0 to 1) of ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera, the camera ARKit captures through, and received_ts the host-clock seconds at which the app's ARSession delegate received the frame, both read when the frame reached the app and so later than its exposure by the capture pipeline's latency",
                "arkit_frame_semantics": ["sceneDepth"],
                "arkit_video_format": Self.describe(videoFormat),
                "arkit_video_formats": ARWorldTrackingConfiguration.supportedVideoFormats.map(Self.describe),
            ]))
    }

    private static func describe(_ format: ARConfiguration.VideoFormat) -> String {
        "\(Int(format.imageResolution.width))x\(Int(format.imageResolution.height)) \(format.framesPerSecond) fps \(format.captureDeviceType.rawValue)"
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
            // Both fail only on an image buffer CoreMedia cannot describe, which ARKit's captured images are not.
            let sample = try! CMSampleBuffer(imageBuffer: image, formatDescription: CMVideoFormatDescription(imageBuffer: image),
                                             sampleTiming: CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: time, decodeTimeStamp: .invalid))
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true)! as NSArray
            (attachments[0] as! NSMutableDictionary)[kCMSampleAttachmentKey_DisplayImmediately] = true
            renderer.enqueue(sample)
        }
    }
}
