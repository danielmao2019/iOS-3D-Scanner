import AVFoundation
import SwiftUI
import UIKit

// One rendered depth view frame: the colorized map and the depth range its colors span.
struct DepthFrame {
    let image: UIImage
    let nearMeters: Float
    let farMeters: Float
}

// Renders the live depth view: each depth map colorized across a fixed depth range, turned upright, and mirrored for the front camera as the color preview is, on a queue of its own; the capture queue only offers maps, and a map is dropped while the view is off, too soon after the last one, or while one is still rendering.
final class DepthPreview {
    // The depth range the colors span, fixed so colors do not shift from frame to frame.
    static let displayRangeMeters: ClosedRange<Float> = 0.2...3.0
    // Just under 1/15 s, so a 30 fps stream yields every second map.
    private static let minInterval = 1.0 / 16

    // Called on the main queue.
    var onFrame: ((DepthFrame) -> Void)?

    private let queue = DispatchQueue(label: "depth.preview", qos: .userInitiated)
    private let lock = NSLock()
    private var enabled = false
    private var busy = false
    private var lastTime = -Double.infinity

    var isEnabled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return enabled }
        set { lock.lock(); enabled = newValue; lock.unlock() }
    }

    // Near is red, far is blue.
    static func hue(atFraction t: Double) -> Double { 0.66 * t }

    private static let palette: [(UInt8, UInt8, UInt8)] = (0..<256).map { i in
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
        UIColor(hue: CGFloat(hue(atFraction: Double(i) / 255)), saturation: 1, brightness: 1, alpha: 1).getRed(&r, green: &g, blue: &b, alpha: nil)
        return (UInt8(r * 255), UInt8(g * 255), UInt8(b * 255))
    }

    func offer(_ depthData: AVDepthData, at time: CMTime, uprightRotationDegrees: Int, camera: DepthCamera) {
        let seconds = CMTimeGetSeconds(time)
        lock.lock()
        let take = enabled && !busy && seconds - lastTime >= Self.minInterval
        if take { (busy, lastTime) = (true, seconds) }
        lock.unlock()
        guard take else { return }
        queue.async {
            let frame = Self.render(depthData, uprightRotationDegrees: uprightRotationDegrees, camera: camera)
            self.lock.lock()
            self.busy = false
            self.lock.unlock()
            DispatchQueue.main.async { self.onFrame?(frame) }
        }
    }

    private static func render(_ depthData: AVDepthData, uprightRotationDegrees: Int, camera: DepthCamera) -> DepthFrame {
        let map = depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32).depthDataMap
        CVPixelBufferLockBaseAddress(map, .readOnly)
        let width = CVPixelBufferGetWidth(map), height = CVPixelBufferGetHeight(map)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(map)
        let base = CVPixelBufferGetBaseAddress(map)!
        let range = Self.displayRangeMeters
        let scale = 255 / (range.upperBound - range.lowerBound)
        // Pixels without a reading stay black.
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBufferPointer { out in
            for y in 0..<height {
                let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: Float32.self)
                for x in 0..<width where row[x].isFinite && row[x] > 0 {
                    let (r, g, b) = palette[Int(min(max((row[x] - range.lowerBound) * scale, 0), 255))]
                    let i = (y * width + x) * 4
                    (out[i], out[i + 1], out[i + 2]) = (r, g, b)
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(map, .readOnly)

        let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                            provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let upright = UIImage(cgImage: image, scale: 1, orientation: displayOrientation(uprightRotationDegrees, mirrored: camera == .front))
        return DepthFrame(image: upright, nearMeters: range.lowerBound, farMeters: range.upperBound)
    }

    // The UIImage orientation that displays a sensor-oriented image rotated clockwise by the given degrees, then, when mirrored, flipped left to right; AVCaptureVideoPreviewLayer mirrors the front camera by default.
    private static func displayOrientation(_ degrees: Int, mirrored: Bool) -> UIImage.Orientation {
        switch ((degrees % 360 + 360) % 360, mirrored) {
        case (0, false): return .up
        case (90, false): return .right
        case (180, false): return .down
        case (270, false): return .left
        case (0, true): return .upMirrored
        case (90, true): return .leftMirrored
        case (180, true): return .downMirrored
        case (270, true): return .rightMirrored
        default: preconditionFailure("upright rotation \(degrees)° is not a multiple of 90°")
        }
    }
}

// The depth view's color scale, labelled with the depth range of the frame on screen.
struct DepthLegend: View {
    let frame: DepthFrame

    var body: some View {
        HStack(spacing: 4) {
            Text(String(format: "%.2f m", frame.nearMeters))
            LinearGradient(colors: stride(from: 0.0, through: 1.0, by: 0.25).map { Color(hue: DepthPreview.hue(atFraction: $0), saturation: 1, brightness: 1) },
                           startPoint: .leading, endPoint: .trailing)
                .frame(width: 80, height: 8)
            Text(String(format: "%.2f m", frame.farMeters))
        }
        .font(.caption2.monospacedDigit()).foregroundStyle(.white)
        .padding(4).background(.black.opacity(0.6)).clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
