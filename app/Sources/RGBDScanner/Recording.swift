import AVFoundation
import CoreMedia
import Foundation
import UIKit

// One recording, captured into a work directory Documents/work/<uuid>/ and then packed, once it has a name, into Documents/<id>.tar with its sidecar Documents/<id>.json.
//
// The two streams are recorded independently, each frame with its own capture timestamp (seconds, host clock); a color frame and a depth frame were captured together when their timestamps are equal.
// All pixels, and the intrinsics, are in the sensor's native orientation, unrotated and unmirrored; each frame records how the phone was held.
// Intrinsics fx,fy,cx,cy are per frame and per stream, each in its own stream's pixels; they are empty on a dropped row, and on a color row whose frame came without them.
//
// The archive:
//   color.mov      HEVC color video; its n-th frame is the row with index n in color.csv. Its display transform is the first frame's upright rotation, so players show it upright.
//   color.csv      one row per color frame delivered or dropped, with the frame's intrinsics in color-frame pixels
//   depth.bin      depth maps exactly as the sensor delivered them (unfiltered), concatenated with no header: map n occupies bytes [n*size, (n+1)*size), size = depth_width*depth_height*depth_bytes_per_pixel, rows tightly packed, little-endian, pixel type depth_pixel_format ("fdep" Float32 metres, "hdep" Float16 metres); NaN or 0 marks a pixel without a reading
//   depth.csv      one row per depth map delivered or dropped, with its intrinsics in depth-map pixels: the calibration's intrinsic matrix (the depth is registered to the color camera) scaled from the intrinsic reference dimensions to the depth map's
//   metadata.json  id, name, duration, device, formats and frame rate, conventions, the first depth map's full calibration at the intrinsic reference dimensions, counts, whether it was recovered after the app stopped, and the color video's error if its writer failed
//
// The work directory holds everything packing needs, so a directory left by a closed app or a failed pack is packed at the next launch:
//   start.json        metadata known when recording starts: camera, start time, device, formats, conventions
//   calibration.json  the first depth map's full calibration, once one has arrived
//   color.mov, color.csv, depth.bin, depth.csv   written as the frames arrive; color.mov is fragmented every second, so it plays up to its last fragment if its writer never finishes
//   sidecar.json      the recording's id, name and duration, fixed when packing begins; a pack that finds it resumes
//   archive.tar.part  the archive being built; each file is deleted once it is in
final class Recording {
    static var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    private static var workRoot: URL { documents.appendingPathComponent("work", isDirectory: true) }
    private static let archived = ["color.mov", "depth.bin", "color.csv", "depth.csv", "metadata.json"]

    static let intrinsicsColumns = "fx,fy,cx,cy"
    static let orientationColumns = "upright_rotation_deg,gravity_x,gravity_y,gravity_z,gravity_ts"
    static let colorHeader = "index,timestamp,dropped," + intrinsicsColumns + "," + orientationColumns
    static let depthHeader = "index,timestamp,dropped,filtered,accuracy,quality," + intrinsicsColumns + "," + orientationColumns

    private let directory: URL
    private let format: CaptureFormat
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let colorTable: FileHandle
    private let depthTable: FileHandle
    private let depthHandle: FileHandle
    private let fileQueue = DispatchQueue(label: "recording.files")
    // Entered until stop() has finished the video, so packing waits for it.
    private let stopped = DispatchGroup()
    private var colorVideoError: String?

    // Owned by fileQueue: the first failed write, after which nothing more is written.
    private var fileError: Error?

    // Owned by the capture data queue.
    private var colorCount = 0
    private var depthCount = 0
    private var hasCalibration = false

    init(camera: DepthCamera, format: CaptureFormat) throws {
        self.format = format
        directory = Self.workRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var systemInfo = utsname()
        uname(&systemInfo)
        var start = format.describe()
        start["camera"] = camera.rawValue
        start["start_time_utc"] = ISO8601DateFormatter().string(from: Date())
        start["depth_filtering_enabled"] = false
        start["device_model"] = withUnsafeBytes(of: &systemInfo.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        start["system_version"] = UIDevice.current.systemVersion
        start["timestamp_clock"] = "host time (CMClockGetHostTimeClock), seconds; shared by color.csv, depth.csv and gravity_ts"
        start["orientation_convention"] = "pixels and intrinsics are in the sensor's native orientation, unrotated and unmirrored; rotating a frame clockwise by its upright_rotation_deg makes it upright (horizon-level); gravity_x/y/z is CoreMotion gravity in g in the phone's device frame (x right, y toward the top of the phone held in portrait, z out of the screen)"
        try JSONSerialization.data(withJSONObject: start, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("start.json"))

        writer = try AVAssetWriter(outputURL: directory.appendingPathComponent("color.mov"), fileType: .mov)
        writer.movieFragmentInterval = CMTime(value: 1, timescale: 1)
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: Int(format.colorDimensions.width),
            AVVideoHeightKey: Int(format.colorDimensions.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 60_000_000,
                AVVideoExpectedSourceFrameRateKey: Int(format.frameRate.rounded()),
                AVVideoAllowFrameReorderingKey: false,
            ],
        ])
        videoInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput) else { throw RecorderError("cannot add video writer input") }
        writer.add(videoInput)

        colorTable = try Self.create(directory.appendingPathComponent("color.csv"), Data((Self.colorHeader + "\n").utf8))
        depthTable = try Self.create(directory.appendingPathComponent("depth.csv"), Data((Self.depthHeader + "\n").utf8))
        depthHandle = try Self.create(directory.appendingPathComponent("depth.bin"), Data())
        stopped.enter()
    }

    private static func create(_ url: URL, _ contents: Data) throws -> FileHandle {
        guard FileManager.default.createFile(atPath: url.path, contents: contents) else { throw RecorderError("cannot create \(url.lastPathComponent)") }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        return handle
    }

    // The frame calls below, and stop(), run on the capture data queue.

    // Returns whether the frame went into the video; a frame the writer does not take is recorded as dropped.
    func appendColor(_ buffer: CMSampleBuffer, orientation: Orientation) -> Bool {
        let time = CMSampleBufferGetPresentationTimeStamp(buffer)
        if writer.status == .unknown {
            // Display only: the stored pixels stay in sensor orientation.
            videoInput.transform = CGAffineTransform(rotationAngle: CGFloat(orientation.uprightRotationDegrees) * .pi / 180)
            writer.startWriting()
            writer.startSession(atSourceTime: time)
        }
        guard videoInput.isReadyForMoreMediaData, videoInput.append(buffer) else {
            recordDroppedColor(at: time, reason: writer.status == .failed ? "writer_failed" : "writer_busy")
            return false
        }
        var intrinsics = ["", "", "", ""]
        if let matrix = CMGetAttachment(buffer, key: kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix, attachmentModeOut: nil) as? Data {
            intrinsics = Self.intrinsics(matrix.withUnsafeBytes { $0.loadUnaligned(as: matrix_float3x3.self) }, scaleX: 1, scaleY: 1)
        }
        append([String(colorCount), seconds(time), ""] + intrinsics + [Self.columns(orientation)], to: colorTable)
        colorCount += 1
        return true
    }

    func recordDroppedColor(at time: CMTime, reason: String) {
        append(["-1", seconds(time), reason] + Array(repeating: "", count: 4) + [Self.columns(nil)], to: colorTable)
    }

    func appendDepth(_ depthData: AVDepthData, at time: CMTime, orientation: Orientation) {
        let map = depthData.depthDataMap
        writeDepthMap(map)
        var intrinsics = ["", "", "", ""]
        if let cal = depthData.cameraCalibrationData {
            let reference = cal.intrinsicMatrixReferenceDimensions
            intrinsics = Self.intrinsics(cal.intrinsicMatrix,
                                         scaleX: Float(CVPixelBufferGetWidth(map)) / Float(reference.width),
                                         scaleY: Float(CVPixelBufferGetHeight(map)) / Float(reference.height))
            if !hasCalibration {
                hasCalibration = true
                let described = Self.describe(cal)
                perform { [directory] in
                    try JSONSerialization.data(withJSONObject: described, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("calibration.json"))
                }
            }
        }
        append([
            String(depthCount), seconds(time), "",
            depthData.isDepthDataFiltered ? "1" : "0",
            depthData.depthDataAccuracy == .absolute ? "absolute" : "relative",
            depthData.depthDataQuality == .high ? "high" : "low",
        ] + intrinsics + [Self.columns(orientation)], to: depthTable)
        depthCount += 1
    }

    func recordDroppedDepth(at time: CMTime, reason: String) {
        append(["-1", seconds(time), reason] + Array(repeating: "", count: 7) + [Self.columns(nil)], to: depthTable)
    }

    // Copies the map's rows without their padding, then writes them off the capture queue.
    private func writeDepthMap(_ map: CVPixelBuffer) {
        let width = CVPixelBufferGetWidth(map), height = CVPixelBufferGetHeight(map)
        precondition(width == Int(format.depthDimensions.width) && height == Int(format.depthDimensions.height) && CVPixelBufferGetPixelFormatType(map) == format.depthPixelFormat,
                     "depth map differs from the active depth format")
        let rowBytes = width * format.depthBytesPerPixel
        var bytes = Data(count: rowBytes * height)
        CVPixelBufferLockBaseAddress(map, .readOnly)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(map)
        let base = CVPixelBufferGetBaseAddress(map)!
        bytes.withUnsafeMutableBytes { dst in
            for y in 0..<height {
                memcpy(dst.baseAddress!.advanced(by: y * rowBytes), base.advanced(by: y * bytesPerRow), rowBytes)
            }
        }
        CVPixelBufferUnlockBaseAddress(map, .readOnly)
        perform { [depthHandle] in try depthHandle.write(contentsOf: bytes) }
    }

    private func append(_ row: [String], to table: FileHandle) {
        let line = Data((row.joined(separator: ",") + "\n").utf8)
        perform { try table.write(contentsOf: line) }
    }

    // Runs a file write on the file queue, in the order the writes were asked for.
    private func perform(_ write: @escaping () throws -> Void) {
        fileQueue.async { [self] in
            guard fileError == nil else { return }
            do { try write() } catch { fileError = error }
        }
    }

    // Ends the recording at this moment; the video finishes in the background.
    func stop() {
        switch writer.status {
        case .writing:
            videoInput.markAsFinished()
            writer.finishWriting { [self] in
                if writer.status == .failed { colorVideoError = (writer.error ?? RecorderError("video writer failed")).localizedDescription }
                stopped.leave()
            }
        case .failed:
            colorVideoError = (writer.error ?? RecorderError("video writer failed")).localizedDescription
            stopped.leave()
        default:
            // No color frame arrived, so the writer never started.
            stopped.leave()
        }
    }

    // Once the video is finished, packs the recording; userName is nil when the user left it unnamed.
    func pack(userName: String?, completion: @escaping (Result<RecordingInfo?, Error>) -> Void) {
        stopped.notify(queue: fileQueue) { [self] in
            completion(Result {
                for handle in [colorTable, depthTable, depthHandle] { try handle.close() }
                if let fileError { throw fileError }
                return try Self.pack(directory, userName: userName, colorVideoError: colorVideoError, recovered: false)
            })
        }
    }

    // Work directories of recordings that were never packed.
    static func leftovers() -> [URL] {
        // Documents/work does not exist before the first recording.
        (try? FileManager.default.contentsOfDirectory(at: workRoot, includingPropertiesForKeys: nil)) ?? []
    }

    // Packs a work directory into Documents/<id>.tar with its sidecar Documents/<id>.json and removes the directory, resuming a pack that was cut short. Returns nil, removing the directory, when a stream has no frames; a failed pack leaves the directory to be packed at the next launch.
    static func pack(_ directory: URL, userName: String?, colorVideoError: String?, recovered: Bool) throws -> RecordingInfo? {
        let pending = directory.appendingPathComponent("sidecar.json")
        if !FileManager.default.fileExists(atPath: pending.path) {
            guard let info = try writeMetadata(directory, userName: userName, colorVideoError: colorVideoError, recovered: recovered) else {
                try FileManager.default.removeItem(at: directory)
                return nil
            }
            try info.write(to: pending)
        }
        let info = try RecordingInfo.load(pending)
        if !FileManager.default.fileExists(atPath: info.tar.path) {
            let part = directory.appendingPathComponent("archive.tar.part")
            try Tar.pack(archived.map { directory.appendingPathComponent($0) }, root: info.id, into: part)
            try info.write(to: info.sidecar)
            try FileManager.default.moveItem(at: part, to: info.tar)
        }
        try FileManager.default.removeItem(at: directory)
        return info
    }

    // Writes metadata.json from start.json, calibration.json and the tables, and returns the recording's sidecar; nil when a stream has no frames.
    private static func writeMetadata(_ directory: URL, userName: String?, colorVideoError: String?, recovered: Bool) throws -> RecordingInfo? {
        let file = { (name: String) in directory.appendingPathComponent(name) }
        var metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: file("start.json"))) as! [String: Any]
        let color = try Table(file("color.csv")), depth = try Table(file("depth.csv"))
        guard color.frames > 0, depth.frames > 0 else { return nil }

        // A depth map written just before the app was closed can lack its row.
        let bytesPerFrame = (metadata["depth_width"] as! Int) * (metadata["depth_height"] as! Int) * (metadata["depth_bytes_per_pixel"] as! Int)
        let bin = try FileHandle(forWritingTo: file("depth.bin"))
        guard try bin.seekToEnd() >= UInt64(depth.frames * bytesPerFrame) else { throw RecorderError("depth.bin holds fewer maps than depth.csv") }
        try bin.truncate(atOffset: UInt64(depth.frames * bytesPerFrame))
        try bin.close()

        let startTime = ISO8601DateFormatter().date(from: metadata["start_time_utc"] as! String)!
        let camera = DepthCamera(rawValue: metadata["camera"] as! String)!
        // An unnamed recording is named by its start date and time.
        let info = RecordingInfo(id: id(startTime, camera, userName), name: userName ?? formatted(startTime, "yyyy-MM-dd HH:mm:ss"), namedByUser: userName != nil,
                                 startTime: startTime, durationSeconds: max(color.last, depth.last) - min(color.first, depth.first),
                                 camera: camera, uploaded: false, colorVideoError: colorVideoError)
        metadata["format_version"] = 3
        metadata["id"] = info.id
        metadata["name"] = info.name
        metadata["named_by_user"] = info.namedByUser
        metadata["duration_s"] = info.durationSeconds
        metadata["recovered"] = recovered
        metadata["color_video_error"] = colorVideoError ?? NSNull()
        metadata["color_frames"] = color.frames
        metadata["depth_frames"] = depth.frames
        metadata["depth_bytes_per_frame"] = bytesPerFrame
        metadata["depth_calibration_first_frame"] = FileManager.default.fileExists(atPath: file("calibration.json").path)
            ? try JSONSerialization.jsonObject(with: Data(contentsOf: file("calibration.json"))) : NSNull()
        try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys]).write(to: file("metadata.json"))
        return info
    }

    // The delivered frames of color.csv or depth.csv, and the first and last timestamps of all its rows.
    private struct Table {
        var frames = 0
        var first = Double.infinity
        var last = -Double.infinity

        init(_ url: URL) throws {
            for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n").dropFirst() {
                let fields = line.split(separator: ",", maxSplits: 2, omittingEmptySubsequences: false)
                guard fields.count == 3, let time = Double(fields[1]) else { throw RecorderError("bad row in \(url.lastPathComponent): \(line)") }
                if fields[0] != "-1" { frames += 1 }
                first = min(first, time)
                last = max(last, time)
            }
        }
    }

    // rgbd_<start>_<camera>, then the user's name, if given, reduced to [A-Za-z0-9_-] and at most 40 characters.
    private static func id(_ startTime: Date, _ camera: DepthCamera, _ userName: String?) -> String {
        let base = "rgbd_\(formatted(startTime, "yyyyMMdd_HHmmss"))_\(camera.rawValue)"
        guard let userName else { return base }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")
        let suffix = String(String.UnicodeScalarView(userName.unicodeScalars.map { allowed.contains($0) ? $0 : "_" }).prefix(40))
        return base + "_" + suffix
    }

    private static func formatted(_ date: Date, _ pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = pattern
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }

    // fx, fy, cx, cy of an intrinsic matrix, with x scaled by scaleX and y by scaleY.
    private static func intrinsics(_ k: matrix_float3x3, scaleX: Float, scaleY: Float) -> [String] {
        [k.columns.0.x * scaleX, k.columns.1.y * scaleY, k.columns.2.x * scaleX, k.columns.2.y * scaleY].map { String($0) }
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
