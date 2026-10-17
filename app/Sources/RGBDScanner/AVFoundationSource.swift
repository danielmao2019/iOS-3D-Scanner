import AVFoundation
import ImageIO
import UIKit

// The front TrueDepth camera through an AVCaptureSession: color and depth come from two outputs, each frame with its own timestamp; depth is unfiltered, and the lens autofocuses when it can move.
final class AVFoundationSource: NSObject, CaptureSource, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureDepthDataOutputDelegate {
    static var frontDevice: AVCaptureDevice? { AVCaptureDevice.default(.builtInTrueDepthCamera, for: .video, position: .front) }

    let device: AVCaptureDevice
    let preview: UIView
    private let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let depthOutput = AVCaptureDepthDataOutput()
    private weak var sink: CaptureSink?
    private let queue: DispatchQueue

    // Owned by queue: the start's ready and the formats it configured, until the first color frame gives the stream format.
    private var pending: (ready: (Result<StreamFormat, Error>) -> Void, format: CaptureFormat)?

    // Both outputs deliver on queue, so the sink sees the frames in arrival order.
    init(sink: CaptureSink, queue: DispatchQueue) {
        guard let device = Self.frontDevice else { preconditionFailure("the front TrueDepth camera is not available") }
        self.device = device
        self.sink = sink
        self.queue = queue
        let view = PreviewLayerView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspect
        view.backgroundColor = .black
        preview = view
        super.init()
        NotificationCenter.default.addObserver(forName: .AVCaptureSessionWasInterrupted, object: session, queue: nil) { [weak self] notification in
            let reason = (notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int).flatMap(AVCaptureSession.InterruptionReason.init(rawValue:))
            self?.sink?.interrupted(Self.describe(reason))
        }
        NotificationCenter.default.addObserver(forName: .AVCaptureSessionRuntimeError, object: session, queue: nil) { [weak self] notification in
            let error = notification.userInfo?[AVCaptureSessionErrorKey] as? Error
            self?.sink?.interrupted("the camera failed: \(error?.localizedDescription ?? "unknown error")")
        }
    }

    func start(ready: @escaping (Result<StreamFormat, Error>) -> Void) {
        // Intrinsic matrix delivery can be enabled only while the session is stopped.
        if session.isRunning { session.stopRunning() }
        do {
            let format = try configure()
            queue.sync { pending = (ready, format) }
            session.startRunning()
        } catch {
            ready(.failure(error))
        }
    }

    func stop() {
        session.stopRunning()
        queue.sync { pending = nil }
    }

    private func configure() throws -> CaptureFormat {
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
        videoOutput.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(videoOutput) else { throw RecorderError("cannot add video output") }
        session.addOutput(videoOutput)

        // Raw sensor depth: Apple's filter would smooth the stream over time and interpolate missing values.
        depthOutput.isFilteringEnabled = false
        depthOutput.alwaysDiscardsLateDepthData = false
        depthOutput.setDelegate(self, callbackQueue: queue)
        guard session.canAddOutput(depthOutput) else { throw RecorderError("cannot add depth output") }
        session.addOutput(depthOutput)

        // Depth formats can be chosen only once the depth output is attached.
        guard let format = CaptureFormat.best(for: device) else { throw RecorderError("no format with depth") }
        try device.lockForConfiguration()
        device.activeFormat = format.color
        device.activeDepthDataFormat = format.depth
        device.activeVideoMinFrameDuration = CaptureFormat.frameDuration
        device.activeVideoMaxFrameDuration = CaptureFormat.frameDuration
        device.activeDepthDataMinFrameDuration = CaptureFormat.frameDuration
        // A lens that cannot move is fixed-focus hardware.
        if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
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
        return format
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let image = CMSampleBufferGetImageBuffer(sampleBuffer) else { preconditionFailure("a video sample without an image") }
        if let pending {
            self.pending = nil
            pending.ready(.success(pending.format.stream(firstFrame: image)))
        }
        let matrix = CMGetAttachment(sampleBuffer, key: kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix, attachmentModeOut: nil) as? Data
        guard let exif = CMGetAttachment(sampleBuffer, key: kCGImagePropertyExifDictionary, attachmentModeOut: nil) as? [String: Any],
              let exposureDuration = exif[kCGImagePropertyExifExposureTime as String] as? Double else { preconditionFailure("a video sample without its Exif exposure time") }
        sink?.captured(color: ColorSample(
            time: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
            image: image,
            intrinsics: matrix.map { m in m.withUnsafeBytes { $0.loadUnaligned(as: matrix_float3x3.self) } },
            exposureDuration: exposureDuration,
            pose: nil))
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        sink?.droppedColor(at: CMSampleBufferGetPresentationTimeStamp(sampleBuffer), reason: "dropped")
    }

    func depthDataOutput(_ output: AVCaptureDepthDataOutput, didOutput depthData: AVDepthData, timestamp: CMTime, connection: AVCaptureConnection) {
        let map = depthData.depthDataMap
        let cal = depthData.cameraCalibrationData
        // The depth is registered to the color camera; the calibration's intrinsics are at its reference dimensions, measured from the upper left of the frame.
        let intrinsics = cal.map { cal in
            scaled(cal.intrinsicMatrix,
                   scaleX: Float(CVPixelBufferGetWidth(map)) / Float(cal.intrinsicMatrixReferenceDimensions.width),
                   scaleY: Float(CVPixelBufferGetHeight(map)) / Float(cal.intrinsicMatrixReferenceDimensions.height))
        }
        sink?.captured(depth: DepthSample(
            time: timestamp,
            map: map,
            metres: depthData.depthDataType == kCVPixelFormatType_DepthFloat32 ? map : depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32).depthDataMap,
            confidence: nil,
            intrinsics: intrinsics,
            flags: DepthFlags(filtered: depthData.isDepthDataFiltered, accuracy: depthData.depthDataAccuracy, quality: depthData.depthDataQuality),
            calibration: cal.map(Self.calibration)))
    }

    func depthDataOutput(_ output: AVCaptureDepthDataOutput, didDrop depthData: AVDepthData, timestamp: CMTime, connection: AVCaptureConnection, reason: AVCaptureOutput.DataDroppedReason) {
        sink?.droppedDepth(at: timestamp, reason: Self.describe(reason))
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

    private static func describe(_ reason: AVCaptureOutput.DataDroppedReason) -> String {
        switch reason {
        case .lateData: return "late"
        case .outOfBuffers: return "out_of_buffers"
        case .discontinuity: return "discontinuity"
        default: return "unknown"
        }
    }

    // The parts of a depth map's calibration the recording writes beside its intrinsics.
    private static func calibration(_ cal: AVCameraCalibrationData) -> Calibration {
        func floats(_ data: Data) -> [Float] { data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) } }
        return Calibration(referenceDimensions: cal.intrinsicMatrixReferenceDimensions, distortionCenter: cal.lensDistortionCenter,
                           lookupTable: cal.lensDistortionLookupTable.map(floats), inverseLookupTable: cal.inverseLensDistortionLookupTable.map(floats), extrinsicMatrix: cal.extrinsicMatrix)
    }

    // Shows the session's color stream; AVCaptureVideoPreviewLayer mirrors the front camera by default.
    private final class PreviewLayerView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}

// The color and depth formats a recording uses, and the frame duration both streams share.
private struct CaptureFormat {
    // Color and depth run at this one duration, so every depth map is captured at the instant of a color frame.
    static let frameDuration = CMTime(value: 1, timescale: CMTimeScale(StreamFormat.framesPerSecond))
    // The color frame size, the camera's 4:3 view at 1920 wide: a frame of 4.1 MB, where a 4032 x 3024 frame took 18.3 MB.
    static let colorWidth = 1920
    static let colorHeight = 1440

    let color: AVCaptureDevice.Format
    let depth: AVCaptureDevice.Format

    // The stream format, the color size and YCbCr matrix read from the first delivered color frame.
    func stream(firstFrame image: CVPixelBuffer) -> StreamFormat {
        let depthDims = CMVideoFormatDescriptionGetDimensions(depth.formatDescription)
        return StreamFormat(
            colorWidth: CVPixelBufferGetWidth(image), colorHeight: CVPixelBufferGetHeight(image), colorYCbCrMatrix: ycbcrMatrix(image),
            depthWidth: Int(depthDims.width), depthHeight: Int(depthDims.height), depthPixelFormat: CMFormatDescriptionGetMediaSubType(depth.formatDescription),
            confidencePixelFormat: nil,
            frameRate: Double(StreamFormat.framesPerSecond),
            // Apple measures the principal points of the frames' intrinsic matrices and of the depth calibration's from "the upper left of the frame"; Recording carries a color frame's to the frame's corner as the calibration's (Intrinsics.carriedAboutCorner).
            principalPointOrigin: .upperLeftPixelCorner)
    }

    // The pair with the largest depth map, then the most precise depth type, among the pairs of a colorWidth x colorHeight color format and a depth format that both run at frameDuration.
    static func best(for device: AVCaptureDevice) -> CaptureFormat? {
        // Each depth type's precision rank.
        let depthRanks: [OSType: Int] = [
            kCVPixelFormatType_DepthFloat32: 3,
            kCVPixelFormatType_DepthFloat16: 2,
            kCVPixelFormatType_DisparityFloat32: 1,
            kCVPixelFormatType_DisparityFloat16: 0,
        ]
        var best: (CaptureFormat, [Int])?
        for color in device.formats where CMFormatDescriptionGetMediaSubType(color.formatDescription) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange && supportsFrameDuration(color) {
            let colorDims = CMVideoFormatDescriptionGetDimensions(color.formatDescription)
            guard colorDims.width == colorWidth && colorDims.height == colorHeight else { continue }
            for depth in color.supportedDepthDataFormats where supportsFrameDuration(depth) {
                guard let depthRank = depthRanks[CMFormatDescriptionGetMediaSubType(depth.formatDescription)] else { continue }
                let depthDims = CMVideoFormatDescriptionGetDimensions(depth.formatDescription)
                // Several formats of one size can offer depth, which this picks among.
                let key = [Int(depthDims.width) * Int(depthDims.height), depthRank]
                if best == nil || best!.1.lexicographicallyPrecedes(key) {
                    best = (CaptureFormat(color: color, depth: depth), key)
                }
            }
        }
        return best?.0
    }

    // Whether frameDuration lies inside one of the format's supported frame rate ranges.
    private static func supportsFrameDuration(_ format: AVCaptureDevice.Format) -> Bool {
        format.videoSupportedFrameRateRanges.contains { $0.minFrameDuration <= frameDuration && frameDuration <= $0.maxFrameDuration }
    }
}
