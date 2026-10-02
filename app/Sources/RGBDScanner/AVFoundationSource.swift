import AVFoundation
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
        device.activeVideoMinFrameDuration = format.frameDuration
        device.activeVideoMaxFrameDuration = format.frameDuration
        device.activeDepthDataMinFrameDuration = format.frameDuration
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
            pending.ready(.success(pending.format.stream(firstFrame: image, focus: device.focusMode == .continuousAutoFocus ? "autofocus" : "fixed")))
        }
        let matrix = CMGetAttachment(sampleBuffer, key: kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix, attachmentModeOut: nil) as? Data
        sink?.captured(color: image, at: CMSampleBufferGetPresentationTimeStamp(sampleBuffer), intrinsics: matrix.map { m in m.withUnsafeBytes { $0.loadUnaligned(as: matrix_float3x3.self) } }, pose: nil)
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
            sourceCells: [depthData.isDepthDataFiltered ? "1" : "0", depthData.depthDataAccuracy == .absolute ? "absolute" : "relative", depthData.depthDataQuality == .high ? "high" : "low"],
            calibration: cal.map { cal in { Self.describe(cal) } }))
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

    // The stream format, the color size and YCbCr matrix read from the first delivered color frame; focus is metadata.json's: autofocus or fixed.
    func stream(firstFrame image: CVPixelBuffer, focus: String) -> StreamFormat {
        let depthDims = CMVideoFormatDescriptionGetDimensions(depth.formatDescription)
        return StreamFormat(
            colorWidth: CVPixelBufferGetWidth(image), colorHeight: CVPixelBufferGetHeight(image), colorYCbCrMatrix: ycbcrMatrix(image),
            depthWidth: Int(depthDims.width), depthHeight: Int(depthDims.height), depthPixelFormat: CMFormatDescriptionGetMediaSubType(depth.formatDescription),
            confidencePixelFormat: nil,
            frameRate: 1 / CMTimeGetSeconds(frameDuration),
            details: [
                "focus": focus,
                "intrinsics_convention": "color.csv's fx,fy,cx,cy are each color frame's kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix, in color pixels; depth.csv's are each depth map's own AVDepthData.cameraCalibrationData.intrinsicMatrix carried from intrinsic_reference_width x intrinsic_reference_height to the depth map: with sx = depth_width / intrinsic_reference_width and sy = depth_height / intrinsic_reference_height, fx_d = fx * sx, fy_d = fy * sy, cx_d = cx * sx, cy_d = cy * sy; Apple measures both principal points from \"the upper left of the frame\", the frame's corner, so plain scaling is exact; neither stream is distortion-corrected: calibration.jsonl carries each depth map's lens distortion lookup tables and center, which describe the color camera the depth is registered to",
                "calibration_description": "calibration.jsonl: one line per delivered depth map, in depth.csv's order, {\"index\": n, \"timestamp\": t, \"calibration\": c} with n and t the map's depth.csv index and timestamp, and c the map's AVDepthData.cameraCalibrationData, null when the map came without one: intrinsic_matrix_row_major (intrinsicMatrix, at intrinsic_reference_width x intrinsic_reference_height, its intrinsicMatrixReferenceDimensions), extrinsic_matrix_row_major_3x4 (extrinsicMatrix), pixel_size_mm (pixelSize), lens_distortion_center (lensDistortionCenter), lens_distortion_lookup_table and inverse_lens_distortion_lookup_table (lensDistortionLookupTable and inverseLensDistortionLookupTable as Float32 arrays)",
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
