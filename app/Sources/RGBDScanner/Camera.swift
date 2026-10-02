import ARKit
import AVFoundation
import UIKit

// A depth camera the phone may have: the front TrueDepth camera, recorded through AVFoundation, or the rear LiDAR camera, recorded through ARKit's scene depth.
enum DepthCamera: String, CaseIterable, Identifiable, Codable {
    case front, rear

    var id: String { rawValue }

    var label: String { self == .front ? "Front (TrueDepth)" : "Rear (LiDAR)" }

    var isAvailable: Bool {
        switch self {
        case .front: return AVFoundationSource.frontDevice != nil
        case .rear: return ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
        }
    }

    // Where the camera's depth comes from, as metadata.json's depth_source names it.
    var depthSource: String { self == .front ? "avfoundation_truedepth" : "arkit_scene_depth" }
}

// The streams a capture source delivers, as a recording writes and describes them; every color frame is 420f.
struct StreamFormat {
    let colorWidth: Int
    let colorHeight: Int
    // The first color frame's kCVImageBufferYCbCrMatrixKey, e.g. ITU_R_709_2: the matrix that turns its YCbCr into RGB.
    let colorYCbCrMatrix: String
    let depthWidth: Int
    let depthHeight: Int
    let depthPixelFormat: OSType
    // The pixel format of the per-pixel confidence maps, the size of the depth maps; nil when the source delivers none.
    let confidencePixelFormat: OSType?
    let frameRate: Double
    // Source-specific entries for metadata.json.
    let details: [String: Any]

    // A Y byte per pixel, then a Cb, Cr byte pair per 2 × 2 pixels.
    var colorBytesPerFrame: Int { colorWidth * colorHeight * 3 / 2 }
    var depthBytesPerPixel: Int { [kCVPixelFormatType_DepthFloat16, kCVPixelFormatType_DisparityFloat16].contains(depthPixelFormat) ? 2 : 4 }
    var depthBytesPerFrame: Int { depthWidth * depthHeight * depthBytesPerPixel }

    var summary: String {
        "color \(colorWidth)×\(colorHeight) · depth \(depthWidth)×\(depthHeight) \(fourCC(depthPixelFormat)) · \(String(format: "%.0f", frameRate)) fps"
    }

    // Describes the streams for metadata.json.
    func describe() -> [String: Any] {
        var described: [String: Any] = [
            "color_width": colorWidth,
            "color_height": colorHeight,
            "color_pixel_format": fourCC(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange),
            "color_bytes_per_frame": colorBytesPerFrame,
            "color_ycbcr_matrix": colorYCbCrMatrix,
            "color_description": "color.bin: every delivered color frame exactly as the camera delivered it, uncompressed, concatenated with no header: the frame with color.csv index n occupies bytes [n*color_bytes_per_frame, (n+1)*color_bytes_per_frame), color_bytes_per_frame = color_width*color_height*3/2; color_pixel_format \"420f\", 8-bit full-range YCbCr 4:2:0, stored as its luma plane, color_height rows of color_width bytes (a Y byte per pixel), then its CbCr plane, color_height/2 rows of color_width bytes (a Cb, Cr byte pair per 2x2 pixels), rows tightly packed, in the sensor's native orientation; its RGB is through color_ycbcr_matrix",
            "depth_width": depthWidth,
            "depth_height": depthHeight,
            "depth_pixel_format": fourCC(depthPixelFormat),
            "depth_bytes_per_pixel": depthBytesPerPixel,
            "depth_bytes_per_frame": depthBytesPerFrame,
            "depth_filtering_enabled": false,
            "frame_rate": frameRate,
        ]
        if let confidencePixelFormat {
            precondition(confidencePixelFormat == kCVPixelFormatType_OneComponent8, "confidence pixel format \(fourCC(confidencePixelFormat)) is not one byte per pixel")
            described["confidence_pixel_format"] = fourCC(confidencePixelFormat)
            described["confidence_bytes_per_pixel"] = 1
            described["confidence_description"] = "confidence.bin: one map per depth map, in depth.bin's order and layout (map n occupies bytes [n*depth_width*depth_height, (n+1)*depth_width*depth_height), rows tightly packed), UInt8 per pixel, ARConfidenceLevel of the depth pixel: 0 low, 1 medium, 2 high"
        }
        described.merge(details) { _, _ in preconditionFailure("source details repeat a stream key") }
        return described
    }
}

// Where ARKit placed the rear camera when it captured a color frame.
struct Pose {
    // The color.csv cell: normal, not_available or limited_<reason>.
    let trackingState: String
    // ARCamera.transform: from ARKit's camera frame to its world frame, in metres.
    let worldFromCamera: simd_float4x4
}

// A depth map as a source delivers it, with what the recording writes about it.
struct DepthSample {
    let time: CMTime
    // As delivered, never converted.
    let map: CVPixelBuffer
    // The same depth as Float32 metres, for the depth view and the stats.
    let metres: CVPixelBuffer
    // One UInt8 confidence per depth pixel, when the source delivers confidence.
    let confidence: CVPixelBuffer?
    // In depth-map pixels; nil when the map came without calibration.
    let intrinsics: matrix_float3x3?
    // The depth.csv cells only the camera's source reports, between dropped and fx: filtered, accuracy and quality for the front, none for the rear.
    let sourceCells: [String]
    // The front's calibration of this map, described for calibration.jsonl off the capture queue; nil when the map came without one, and always for the rear, which has none.
    let calibration: (() -> [String: Any])?
}

// Where a capture source delivers frames, on the queue it was given; a color frame comes before a depth frame with the same timestamp.
protocol CaptureSink: AnyObject {
    // A color frame as delivered, with its intrinsics in its pixels (nil when it came without them) and, for the rear, ARKit's pose.
    func captured(color: CVPixelBuffer, at time: CMTime, intrinsics: matrix_float3x3?, pose: Pose?)
    func droppedColor(at time: CMTime, reason: String)
    func captured(depth: DepthSample)
    func droppedDepth(at time: CMTime, reason: String)
    // Called on any queue, when capture is cut off: the camera was interrupted or failed.
    func interrupted(_ reason: String)
}

// A camera's capture pipeline, started and stopped from one serial queue.
protocol CaptureSource: AnyObject {
    // Shows the live color stream; made on the main queue.
    var preview: UIView { get }
    // The capture device whose rotation gives each frame's upright rotation.
    var device: AVCaptureDevice { get }
    // Starts delivering frames; calls ready, on any queue, once with the stream format, or the reason capture cannot start.
    func start(ready: @escaping (Result<StreamFormat, Error>) -> Void)
    func stop()
}

// The YCbCr matrix of a delivered color frame, which must be 420f: its kCVImageBufferYCbCrMatrixKey, e.g. ITU_R_709_2.
func ycbcrMatrix(_ image: CVPixelBuffer) -> String {
    precondition(CVPixelBufferGetPixelFormatType(image) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, "color frame is \(fourCC(CVPixelBufferGetPixelFormatType(image))), not 420f")
    guard let matrix = CVBufferCopyAttachment(image, kCVImageBufferYCbCrMatrixKey, nil) as? String else { preconditionFailure("color frame names no YCbCr matrix") }
    return matrix
}

// An intrinsic matrix whose principal point is measured from the upper-left corner of the image (AVFoundation's "upper left of the frame"), carried to an image of the same view scaleX times as wide and scaleY times as tall: f' = f * scale, c' = c * scale.
func scaled(_ k: matrix_float3x3, scaleX: Float, scaleY: Float) -> matrix_float3x3 {
    var s = k
    s.columns.0.x *= scaleX
    s.columns.2.x *= scaleX
    s.columns.1.y *= scaleY
    s.columns.2.y *= scaleY
    return s
}

// An intrinsic matrix whose principal point is measured from the center of the upper-left pixel (ARKit's convention), carried to an image of the same view scaleX times as wide and scaleY times as tall: the focal lengths scale, and the principal point keeps its place in the view, c' = (c + 0.5) * scale - 0.5.
func resampled(_ k: matrix_float3x3, scaleX: Float, scaleY: Float) -> matrix_float3x3 {
    var s = scaled(k, scaleX: scaleX, scaleY: scaleY)
    s.columns.2.x += 0.5 * scaleX - 0.5
    s.columns.2.y += 0.5 * scaleY - 0.5
    return s
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
