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
}

// Where a camera's intrinsics measure the principal point from, as the recording's intrinsics files name it.
enum PrincipalPointOrigin: String, Codable {
    // The corner of the frame: AVFoundation's "upper left of the frame".
    case upperLeftPixelCorner = "upper_left_pixel_corner"
    // The center of the upper-left pixel, as ARCamera.h says of ARCamera.intrinsics.
    case upperLeftPixelCenter = "upper_left_pixel_center"
}

// The streams a capture source delivers, as a recording writes them; every color frame is 420f.
struct StreamFormat: Codable {
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
    // Where both streams' intrinsics measure the principal point from.
    let principalPointOrigin: PrincipalPointOrigin

    // A Y byte per pixel, then a Cb, Cr byte pair per 2x2 pixels.
    var colorBytesPerFrame: Int { colorWidth * colorHeight * 3 / 2 }
    var depthBytesPerPixel: Int { [kCVPixelFormatType_DepthFloat16, kCVPixelFormatType_DisparityFloat16].contains(depthPixelFormat) ? 2 : 4 }
    var depthBytesPerFrame: Int { depthWidth * depthHeight * depthBytesPerPixel }

    var summary: String {
        "color \(colorWidth)x\(colorHeight), depth \(depthWidth)x\(depthHeight) \(fourCC(depthPixelFormat)), \(String(format: "%.0f", frameRate)) fps"
    }
}

// Where ARKit placed the rear camera when it captured a color frame.
struct Pose {
    // ARKit's tracking state when it estimated the pose: normal, not_available or limited_<reason>.
    let trackingState: String
    // ARCamera.transform: from ARKit's camera frame to its world frame, in metres.
    let worldFromCamera: simd_float4x4
}

// A color frame as a source delivers it, with what the recording writes about it.
struct ColorSample {
    let time: CMTime
    // As delivered, 420f.
    let image: CVPixelBuffer
    // In color pixels; nil when the frame came without them.
    let intrinsics: matrix_float3x3?
    // The frame's own exposure time, in seconds.
    let exposureDuration: Double
    // ARKit's pose of the rear camera; nil for the front, which has none.
    let pose: Pose?
}

// What AVDepthData says of a front depth map.
struct DepthFlags {
    // isDepthDataFiltered.
    let filtered: Bool
    let accuracy: AVDepthData.Accuracy
    let quality: AVDepthData.Quality
}

// What a front depth map's AVCameraCalibrationData says beyond the map's intrinsics; it describes the color camera the depth is registered to.
struct Calibration {
    // intrinsicMatrixReferenceDimensions: the image size the intrinsic matrix and the distortion center are in.
    let referenceDimensions: CGSize
    // lensDistortionCenter, in reference pixels, measured from the frame's corner as the intrinsic matrix is.
    let distortionCenter: CGPoint
    // lensDistortionLookupTable and inverseLensDistortionLookupTable, radius-normalized; nil when Apple gives none, which leaves the lens distortion unknown.
    let lookupTable: [Float]?
    let inverseLookupTable: [Float]?
    // extrinsicMatrix: from the depth camera to the color camera, rotation and translation in metres.
    let extrinsicMatrix: matrix_float4x3
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
    // The front's; nil for the rear.
    let flags: DepthFlags?
    // The front's calibration of this map; nil when the map came without one, and always for the rear, which has none.
    let calibration: Calibration?
}

// Where a capture source delivers frames, on the queue it was given; a color frame comes before a depth frame with the same timestamp.
protocol CaptureSink: AnyObject {
    func captured(color: ColorSample)
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
    // The capture device whose rotation gives each color frame's upright rotation.
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

// ARKit's intrinsics, in capturedImage pixels with the principal point measured from the center of the upper-left pixel, carried to its scene depth map, scaleX times as wide and scaleY times as tall, as the depth grid lies on the image, which six rear scans (2026-09-30 to 2026-10-02) measured from where depth edges land on color edges, x and y differing: along x the depth grid's first column center sits on the image's first column center, cx' = cx * scaleX; along y the depth rows span the image rows edge to edge, cy' = (cy + 0.5) * scaleY - 0.5; the focal lengths scale, f' = f * scale.
func arkitDepthIntrinsics(_ k: matrix_float3x3, scaleX: Float, scaleY: Float) -> matrix_float3x3 {
    var s = k
    s.columns.0.x *= scaleX
    s.columns.1.y *= scaleY
    s.columns.2.x *= scaleX
    s.columns.2.y = (k.columns.2.y + 0.5) * scaleY - 0.5
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
