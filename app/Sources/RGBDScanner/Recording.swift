import AVFoundation
import CoreMedia
import Foundation
import UIKit

// One recording: written to a directory while recording, then packed into Documents/<name>.tar.
//
// The two streams are recorded independently, each frame with its own capture timestamp (seconds, host clock); a color frame and a depth frame were captured together when their timestamps are equal.
// All pixels, and the intrinsics, are in the sensor's native orientation, unrotated and unmirrored; each frame records how the phone was held.
//
//   color.mov      HEVC color video; its n-th frame is the row with index n in color.csv. Its display transform is the first frame's upright rotation, so players show it upright.
//   color.csv      one row per color frame delivered or dropped
//   depth.bin      depth maps exactly as the sensor delivered them (unfiltered), concatenated with no header: map n occupies bytes
//                  [n*size, (n+1)*size), size = depth_width*depth_height*depth_bytes_per_pixel, rows tightly packed, little-endian,
//                  pixel type depth_pixel_format ("fdep" Float32 metres, "hdep" Float16 metres); NaN or 0 marks a pixel without a reading
//   depth.csv      one row per depth map delivered or dropped, with its calibration intrinsics (the depth is registered to the color camera, so these are the color camera's intrinsics at intrinsic reference dimensions)
//   metadata.json  device, formats, conventions, first depth map's full calibration, counts
final class Recording {
    let name: String
    private let directory: URL
    private var metadata: [String: Any]

    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let depthHandle: FileHandle
    private let fileQueue = DispatchQueue(label: "recording.files")

    private var colorRows: [String] = []
    private var depthRows: [String] = []
    private var colorCount = 0
    private var depthCount = 0
    private var depthBytesPerFrame = 0
    private var calibration: [String: Any]?
    private let startDate = Date()

    static let orientationColumns = "upright_rotation_deg,gravity_x,gravity_y,gravity_z,gravity_ts"
    static let colorHeader = "index,timestamp,dropped," + orientationColumns
    static let depthHeader = "index,timestamp,dropped,filtered,accuracy,quality,fx,fy,cx,cy,intrinsic_ref_width,intrinsic_ref_height," + orientationColumns

    static var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }

    init(camera: DepthCamera, format: CaptureFormat) throws {
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd_HHmmss"
        stamp.locale = Locale(identifier: "en_US_POSIX")
        name = "rgbd_\(stamp.string(from: Date()))_\(camera.rawValue)"
        directory = Recording.documents.appendingPathComponent("work", isDirectory: true).appendingPathComponent(name, isDirectory: true)
        metadata = format.describe()
        metadata["camera"] = camera.rawValue
        metadata["depth_filtering_enabled"] = false

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        writer = try AVAssetWriter(outputURL: directory.appendingPathComponent("color.mov"), fileType: .mov)
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: Int(format.colorDimensions.width),
            AVVideoHeightKey: Int(format.colorDimensions.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 60_000_000,
                AVVideoExpectedSourceFrameRateKey: Int(CaptureFormat.frameRate),
                AVVideoAllowFrameReorderingKey: false,
            ],
        ])
        videoInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput) else { throw RecorderError("cannot add video writer input") }
        writer.add(videoInput)

        let depthURL = directory.appendingPathComponent("depth.bin")
        FileManager.default.createFile(atPath: depthURL.path, contents: nil)
        depthHandle = try FileHandle(forWritingTo: depthURL)
    }

    // The frame calls below run on the capture data queue.

    func appendColor(_ buffer: CMSampleBuffer, orientation: Orientation) {
        let time = CMSampleBufferGetPresentationTimeStamp(buffer)
        if writer.status == .unknown {
            // Display only: the stored pixels stay in sensor orientation.
            videoInput.transform = CGAffineTransform(rotationAngle: CGFloat(orientation.uprightRotationDegrees) * .pi / 180)
            writer.startWriting()
            writer.startSession(atSourceTime: time)
        }
        guard videoInput.isReadyForMoreMediaData, videoInput.append(buffer) else {
            return recordDroppedColor(at: time, reason: "writer_busy")
        }
        colorRows.append([String(colorCount), seconds(time), "", Self.columns(orientation)].joined(separator: ","))
        colorCount += 1
    }

    func recordDroppedColor(at time: CMTime, reason: String) {
        colorRows.append(["-1", seconds(time), reason, Self.columns(nil)].joined(separator: ","))
    }

    func appendDepth(_ depthData: AVDepthData, at time: CMTime, orientation: Orientation) {
        writeDepthMap(depthData.depthDataMap)
        var intrinsics = ["", "", "", "", "", ""]
        if let cal = depthData.cameraCalibrationData {
            let k = cal.intrinsicMatrix
            intrinsics = [k.columns.0.x, k.columns.1.y, k.columns.2.x, k.columns.2.y].map { String($0) }
                + [String(Int(cal.intrinsicMatrixReferenceDimensions.width)), String(Int(cal.intrinsicMatrixReferenceDimensions.height))]
            if calibration == nil { calibration = Self.describe(cal) }
        }
        depthRows.append(([
            String(depthCount), seconds(time), "",
            depthData.isDepthDataFiltered ? "1" : "0",
            depthData.depthDataAccuracy == .absolute ? "absolute" : "relative",
            depthData.depthDataQuality == .high ? "high" : "low",
        ] + intrinsics + [Self.columns(orientation)]).joined(separator: ","))
        depthCount += 1
    }

    func recordDroppedDepth(at time: CMTime, reason: String) {
        depthRows.append((["-1", seconds(time), reason] + Array(repeating: "", count: 9) + [Self.columns(nil)]).joined(separator: ","))
    }

    // Copies the map's rows without their padding, then writes them off the capture queue.
    private func writeDepthMap(_ map: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(map, .readOnly)
        let width = CVPixelBufferGetWidth(map), height = CVPixelBufferGetHeight(map)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(map)
        let pixelFormat = CVPixelBufferGetPixelFormatType(map)
        let bytesPerPixel = (pixelFormat == kCVPixelFormatType_DepthFloat16 || pixelFormat == kCVPixelFormatType_DisparityFloat16) ? 2 : 4
        let rowBytes = width * bytesPerPixel
        var bytes = Data(count: rowBytes * height)
        let base = CVPixelBufferGetBaseAddress(map)!
        bytes.withUnsafeMutableBytes { dst in
            for y in 0..<height {
                memcpy(dst.baseAddress!.advanced(by: y * rowBytes), base.advanced(by: y * bytesPerRow), rowBytes)
            }
        }
        CVPixelBufferUnlockBaseAddress(map, .readOnly)

        if depthBytesPerFrame == 0 {
            depthBytesPerFrame = bytes.count
            metadata["depth_width"] = width
            metadata["depth_height"] = height
            metadata["depth_pixel_format"] = fourCC(pixelFormat)
            metadata["depth_bytes_per_pixel"] = bytesPerPixel
        }
        precondition(bytes.count == depthBytesPerFrame, "depth map size changed mid-recording")
        fileQueue.async { [depthHandle] in depthHandle.write(bytes) }
    }

    // Finishes the video, writes the tables and metadata, and packs everything into Documents/<name>.tar.
    func finish(completion: @escaping (Result<URL, Error>) -> Void) {
        let packFiles = { [self] in
            fileQueue.async { [self] in
                do {
                    depthHandle.closeFile()
                    try Self.writeTable(Self.colorHeader, colorRows, to: directory.appendingPathComponent("color.csv"))
                    try Self.writeTable(Self.depthHeader, depthRows, to: directory.appendingPathComponent("depth.csv"))
                    try writeMetadata()
                    let tar = Recording.documents.appendingPathComponent("\(name).tar")
                    try Tar.pack(directory: directory, into: tar)
                    try FileManager.default.removeItem(at: directory)
                    completion(.success(tar))
                } catch {
                    completion(.failure(error))
                }
            }
        }
        guard writer.status == .writing else {
            writer.cancelWriting()
            return packFiles()
        }
        videoInput.markAsFinished()
        writer.finishWriting {
            if self.writer.status == .failed {
                completion(.failure(self.writer.error ?? RecorderError("video writer failed")))
            } else {
                packFiles()
            }
        }
    }

    private static func writeTable(_ header: String, _ rows: [String], to url: URL) throws {
        try (([header] + rows).joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func writeMetadata() throws {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machine = withUnsafeBytes(of: &systemInfo.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        var info = metadata
        info["name"] = name
        info["format_version"] = 2
        info["device_model"] = machine
        info["system_version"] = UIDevice.current.systemVersion
        info["start_time_utc"] = ISO8601DateFormatter().string(from: startDate)
        info["timestamp_clock"] = "host time (CMClockGetHostTimeClock), seconds; shared by color.csv, depth.csv and gravity_ts"
        info["orientation_convention"] = "pixels and intrinsics are in the sensor's native orientation, unrotated and unmirrored; rotating a frame clockwise by its upright_rotation_deg makes it upright (horizon-level); gravity_x/y/z is CoreMotion gravity in g in the phone's device frame (x right, y toward the top of the phone held in portrait, z out of the screen)"
        info["color_frames"] = colorCount
        info["depth_frames"] = depthCount
        info["depth_bytes_per_frame"] = depthBytesPerFrame
        info["depth_calibration_first_frame"] = calibration ?? NSNull()
        let data = try JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: directory.appendingPathComponent("metadata.json"))
    }

    // A dropped frame has no orientation.
    private static func columns(_ o: Orientation?) -> String {
        guard let o else { return ",,,," }
        guard let g = o.gravity, let t = o.gravityTime else { return "\(o.uprightRotationDegrees),,,," }
        return [String(o.uprightRotationDegrees), String(format: "%.5f", g.x), String(format: "%.5f", g.y), String(format: "%.5f", g.z), String(format: "%.9f", t)].joined(separator: ",")
    }

    static func describe(_ reason: AVCaptureOutput.DataDroppedReason) -> String {
        switch reason {
        case .lateData: return "late"
        case .outOfBuffers: return "out_of_buffers"
        case .discontinuity: return "discontinuity"
        default: return "unknown"
        }
    }

    static func describe(_ cal: AVCameraCalibrationData) -> [String: Any] {
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
}

private func seconds(_ time: CMTime) -> String {
    String(format: "%.9f", CMTimeGetSeconds(time))
}
