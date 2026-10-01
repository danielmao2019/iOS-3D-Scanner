import ARKit
import AVFoundation
import UIKit

// A depth camera the phone may have: the front TrueDepth camera, recorded through AVFoundation, or the rear LiDAR camera, recorded through AVFoundation or ARKit as the rear depth-source setting chooses.
enum DepthCamera: String, CaseIterable, Identifiable, Codable {
    case front, rear

    var id: String { rawValue }

    var label: String { self == .front ? "Front (TrueDepth)" : "Rear (LiDAR)" }

    var isAvailable: Bool {
        switch self {
        case .front: return AVFoundationSource.frontDevice != nil
        case .rear: return AVFoundationSource.rearDevice != nil && ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
        }
    }
}

// Where a recording's depth comes from, as metadata.json's depth_source names it: the front camera has one source, the rear camera two.
enum DepthSource: String, CaseIterable, Decodable {
    // The TrueDepth camera through AVFoundation.
    case avfoundationTrueDepth = "avfoundation_truedepth"
    // The LiDAR depth camera through AVFoundation, at its highest depth resolution.
    case avfoundationLiDAR = "avfoundation_lidar"
    // ARKit's scene depth, densified by Apple, down to about 0.2 m, with confidence and pose; with the depth filter on, its temporally smoothed variant.
    case arkitSceneDepth = "arkit_scene_depth"

    var camera: DepthCamera { self == .avfoundationTrueDepth ? .front : .rear }
}

// The streams a capture source delivers, as a recording writes and describes them.
struct StreamFormat {
    let colorWidth: Int
    let colorHeight: Int
    let colorPixelFormat: OSType
    let depthWidth: Int
    let depthHeight: Int
    let depthPixelFormat: OSType
    // The pixel format of the per-pixel confidence maps, the size of the depth maps; nil when the source delivers none.
    let confidencePixelFormat: OSType?
    let frameRate: Double
    // Whether the source smooths depth over time and fills holes: AVCaptureDepthDataOutput.isFilteringEnabled through AVFoundation, smoothedSceneDepth instead of sceneDepth through ARKit.
    let depthFilteringEnabled: Bool
    let depthSource: DepthSource
    // Source-specific entries for metadata.json.
    let details: [String: Any]

    var depthBytesPerPixel: Int { [kCVPixelFormatType_DepthFloat16, kCVPixelFormatType_DisparityFloat16].contains(depthPixelFormat) ? 2 : 4 }

    var summary: String {
        "color \(colorWidth)×\(colorHeight) · depth \(depthWidth)×\(depthHeight) \(fourCC(depthPixelFormat))\(depthFilteringEnabled ? " filtered" : "") · \(String(format: "%.0f", frameRate)) fps"
    }

    // Describes the streams for metadata.json.
    func describe() -> [String: Any] {
        var described: [String: Any] = [
            "color_width": colorWidth,
            "color_height": colorHeight,
            "color_pixel_format": fourCC(colorPixelFormat),
            "depth_width": depthWidth,
            "depth_height": depthHeight,
            "depth_pixel_format": fourCC(depthPixelFormat),
            "depth_bytes_per_pixel": depthBytesPerPixel,
            "depth_source": depthSource.rawValue,
            "depth_filtering_enabled": depthFilteringEnabled,
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
    // The full calibration, described for metadata.json, computed only for the recording's first depth map.
    let calibration: (() -> [String: Any])?
    // The depth.csv cells filtered, accuracy and quality.
    let filtered: String
    let accuracy: String
    let quality: String
    // ARKit's camera-to-world pose of the frame and its tracking state; nil for a source without tracking.
    let pose: simd_float4x4?
    let tracking: String?
}

// Where a capture source delivers frames, on the queue it was given; a color frame comes before a depth frame with the same timestamp.
protocol CaptureSink: AnyObject {
    func captured(color: CMSampleBuffer, intrinsics: matrix_float3x3?)
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
    // Starts delivering frames, depth filtered or not; calls ready, on any queue, once with the stream format, or the reason capture cannot start.
    func start(depthFiltering: Bool, ready: @escaping (Result<StreamFormat, Error>) -> Void)
    func stop()
}

// An intrinsic matrix with x scaled by scaleX and y by scaleY, e.g. from one image size to another.
func scaled(_ k: matrix_float3x3, scaleX: Float, scaleY: Float) -> matrix_float3x3 {
    var s = k
    s.columns.0.x *= scaleX
    s.columns.2.x *= scaleX
    s.columns.1.y *= scaleY
    s.columns.2.y *= scaleY
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
