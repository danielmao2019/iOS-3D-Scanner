import AVFoundation

// A depth camera the phone may have: the front TrueDepth camera or the rear LiDAR camera.
enum DepthCamera: String, CaseIterable, Identifiable {
    case front, rear

    var id: String { rawValue }

    var label: String { self == .front ? "Front (TrueDepth)" : "Rear (LiDAR)" }

    var device: AVCaptureDevice? {
        self == .front
            ? AVCaptureDevice.default(.builtInTrueDepthCamera, for: .video, position: .front)
            : AVCaptureDevice.default(.builtInLiDARDepthCamera, for: .video, position: .back)
    }
}

// The color and depth formats a recording uses.
struct CaptureFormat {
    let color: AVCaptureDevice.Format
    let depth: AVCaptureDevice.Format

    static let frameRate: Int32 = 30

    var colorDimensions: CMVideoDimensions { CMVideoFormatDescriptionGetDimensions(color.formatDescription) }
    var depthDimensions: CMVideoDimensions { CMVideoFormatDescriptionGetDimensions(depth.formatDescription) }
    var depthPixelFormat: OSType { CMFormatDescriptionGetMediaSubType(depth.formatDescription) }

    // The format with the largest depth map, then the most precise depth type, then the largest color frame, among those running at 30 fps.
    static func best(for device: AVCaptureDevice) -> CaptureFormat? {
        let depthTypeRank: [OSType: Int] = [
            kCVPixelFormatType_DepthFloat32: 3,
            kCVPixelFormatType_DepthFloat16: 2,
            kCVPixelFormatType_DisparityFloat32: 1,
            kCVPixelFormatType_DisparityFloat16: 0,
        ]
        var best: (CaptureFormat, [Int])?
        for color in device.formats {
            guard CMFormatDescriptionGetMediaSubType(color.formatDescription) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                  color.videoSupportedFrameRateRanges.contains(where: { $0.maxFrameRate >= Double(frameRate) }) else { continue }
            let colorDims = CMVideoFormatDescriptionGetDimensions(color.formatDescription)
            for depth in color.supportedDepthDataFormats {
                guard let rank = depthTypeRank[CMFormatDescriptionGetMediaSubType(depth.formatDescription)] else { continue }
                let depthDims = CMVideoFormatDescriptionGetDimensions(depth.formatDescription)
                let key = [Int(depthDims.width) * Int(depthDims.height), rank, Int(colorDims.width) * Int(colorDims.height)]
                if best == nil || best!.1.lexicographicallyPrecedes(key) {
                    best = (CaptureFormat(color: color, depth: depth), key)
                }
            }
        }
        return best?.0
    }

    // Describes the formats for metadata.json.
    func describe() -> [String: Any] {
        [
            "color_width": Int(colorDimensions.width),
            "color_height": Int(colorDimensions.height),
            "color_pixel_format": fourCC(CMFormatDescriptionGetMediaSubType(color.formatDescription)),
            "depth_width": Int(depthDimensions.width),
            "depth_height": Int(depthDimensions.height),
            "depth_pixel_format": fourCC(depthPixelFormat),
            "frame_rate": Int(Self.frameRate),
            "available_depth_formats": color.supportedDepthDataFormats.map { f -> String in
                let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
                return "\(d.width)x\(d.height) \(fourCC(CMFormatDescriptionGetMediaSubType(f.formatDescription)))"
            },
        ]
    }
}

struct RecorderError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

func fourCC(_ code: OSType) -> String {
    let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xff) }
    return String(bytes: bytes, encoding: .ascii) ?? String(code)
}
