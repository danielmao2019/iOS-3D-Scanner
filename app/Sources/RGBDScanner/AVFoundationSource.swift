import AVFoundation
import UIKit

// The front TrueDepth camera through an AVCaptureSession: color and depth come from two outputs, each frame with its own timestamp, unfiltered.
final class AVFoundationSource: NSObject, CaptureSource, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureDepthDataOutputDelegate {
    static var frontDevice: AVCaptureDevice? { AVCaptureDevice.default(.builtInTrueDepthCamera, for: .video, position: .front) }

    let device: AVCaptureDevice
    let preview: UIView
    private let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let depthOutput = AVCaptureDepthDataOutput()
    private weak var sink: CaptureSink?
    private let queue: DispatchQueue

    // Both outputs deliver on queue, so the sink sees the frames in arrival order.
    init(device: AVCaptureDevice, sink: CaptureSink, queue: DispatchQueue) {
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
        ready(Result {
            // Intrinsic matrix delivery can be enabled only while the session is stopped.
            if session.isRunning { session.stopRunning() }
            let format = try configure()
            session.startRunning()
            return format.stream
        })
    }

    func stop() {
        session.stopRunning()
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

        // Raw sensor depth: Apple's filter smooths the stream over time and interpolates missing values.
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
        return format
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let matrix = CMGetAttachment(sampleBuffer, key: kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix, attachmentModeOut: nil) as? Data
        sink?.captured(color: sampleBuffer, intrinsics: matrix.map { m in m.withUnsafeBytes { $0.loadUnaligned(as: matrix_float3x3.self) } })
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        sink?.droppedColor(at: CMSampleBufferGetPresentationTimeStamp(sampleBuffer), reason: "dropped")
    }

    func depthDataOutput(_ output: AVCaptureDepthDataOutput, didOutput depthData: AVDepthData, timestamp: CMTime, connection: AVCaptureConnection) {
        let map = depthData.depthDataMap
        let cal = depthData.cameraCalibrationData
        // The depth is registered to the color camera; the calibration's intrinsics are at its reference dimensions.
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
            calibration: cal.map { cal in { Self.describe(cal) } },
            filtered: depthData.isDepthDataFiltered ? "1" : "0",
            accuracy: depthData.depthDataAccuracy == .absolute ? "absolute" : "relative",
            quality: depthData.depthDataQuality == .high ? "high" : "low",
            pose: nil,
            tracking: nil))
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

    private static func describe(_ cal: AVCameraCalibrationData) -> [String: Any] {
        let k = cal.intrinsicMatrix
        let e = cal.extrinsicMatrix
        func floats(_ data: Data?) -> [Float] {
            guard let data else { return [] }
            return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        }
        return [
            "intrinsic_matrix_row_major": [
                [k.columns.0.x, k.columns.1.x, k.columns.2.x],
                [k.columns.0.y, k.columns.1.y, k.columns.2.y],
                [k.columns.0.z, k.columns.1.z, k.columns.2.z],
            ],
            "intrinsic_reference_width": cal.intrinsicMatrixReferenceDimensions.width,
            "intrinsic_reference_height": cal.intrinsicMatrixReferenceDimensions.height,
            "extrinsic_matrix_row_major_3x4": [
                [e.columns.0.x, e.columns.1.x, e.columns.2.x, e.columns.3.x],
                [e.columns.0.y, e.columns.1.y, e.columns.2.y, e.columns.3.y],
                [e.columns.0.z, e.columns.1.z, e.columns.2.z, e.columns.3.z],
            ],
            "pixel_size_mm": cal.pixelSize,
            "lens_distortion_center": [cal.lensDistortionCenter.x, cal.lensDistortionCenter.y],
            "lens_distortion_lookup_table": floats(cal.lensDistortionLookupTable),
            "inverse_lens_distortion_lookup_table": floats(cal.inverseLensDistortionLookupTable),
        ]
    }

    // Shows the session's color stream; AVCaptureVideoPreviewLayer mirrors the front camera by default.
    private final class PreviewLayerView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}

// The color and depth formats a recording uses, and the frame duration both streams share.
private struct CaptureFormat {
    let color: AVCaptureDevice.Format
    let depth: AVCaptureDevice.Format
    // Color and depth run at this one duration, so every depth map is captured at the instant of a color frame.
    let frameDuration: CMTime

    var stream: StreamFormat {
        let colorDims = CMVideoFormatDescriptionGetDimensions(color.formatDescription)
        let depthDims = CMVideoFormatDescriptionGetDimensions(depth.formatDescription)
        return StreamFormat(
            colorWidth: Int(colorDims.width), colorHeight: Int(colorDims.height), colorPixelFormat: CMFormatDescriptionGetMediaSubType(color.formatDescription),
            depthWidth: Int(depthDims.width), depthHeight: Int(depthDims.height), depthPixelFormat: CMFormatDescriptionGetMediaSubType(depth.formatDescription),
            confidencePixelFormat: nil,
            frameRate: 1 / CMTimeGetSeconds(frameDuration),
            depthSource: "avfoundation_truedepth",
            details: [
                "available_depth_formats": color.supportedDepthDataFormats.map { f -> String in
                    let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
                    return "\(d.width)x\(d.height) \(fourCC(CMFormatDescriptionGetMediaSubType(f.formatDescription)))"
                },
            ])
    }

    // The pair with the largest depth map, then the most precise depth type, then the largest color frame, at the highest frame rate both formats support.
    static func best(for device: AVCaptureDevice) -> CaptureFormat? {
        let depthTypeRank: [OSType: Int] = [
            kCVPixelFormatType_DepthFloat32: 3,
            kCVPixelFormatType_DepthFloat16: 2,
            kCVPixelFormatType_DisparityFloat32: 1,
            kCVPixelFormatType_DisparityFloat16: 0,
        ]
        var best: (CaptureFormat, [Int])?
        for color in device.formats where CMFormatDescriptionGetMediaSubType(color.formatDescription) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange {
            let colorDims = CMVideoFormatDescriptionGetDimensions(color.formatDescription)
            for depth in color.supportedDepthDataFormats {
                guard let rank = depthTypeRank[CMFormatDescriptionGetMediaSubType(depth.formatDescription)],
                      let frameDuration = shortestCommonFrameDuration(color, depth) else { continue }
                let depthDims = CMVideoFormatDescriptionGetDimensions(depth.formatDescription)
                let key = [Int(depthDims.width) * Int(depthDims.height), rank, Int(colorDims.width) * Int(colorDims.height)]
                if best == nil || best!.1.lexicographicallyPrecedes(key) {
                    best = (CaptureFormat(color: color, depth: depth, frameDuration: frameDuration), key)
                }
            }
        }
        return best?.0
    }

    // The shortest frame duration inside a supported range of both formats.
    private static func shortestCommonFrameDuration(_ color: AVCaptureDevice.Format, _ depth: AVCaptureDevice.Format) -> CMTime? {
        func supports(_ format: AVCaptureDevice.Format, _ duration: CMTime) -> Bool {
            format.videoSupportedFrameRateRanges.contains { $0.minFrameDuration <= duration && duration <= $0.maxFrameDuration }
        }
        return (color.videoSupportedFrameRateRanges + depth.videoSupportedFrameRateRanges).map(\.minFrameDuration)
            .filter { supports(color, $0) && supports(depth, $0) }
            .min()
    }
}
