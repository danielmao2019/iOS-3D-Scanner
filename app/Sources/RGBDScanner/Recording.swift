import AVFoundation
import CoreMedia
import Foundation
import UIKit

// One recording, captured into a work directory Documents/work/<uuid>/ and then packed, once it has a name, into Documents/<id>.tar with its sidecar Documents/<id>.json.
//
// The two streams are recorded independently, each frame with its own capture timestamp (seconds, host clock); a color frame and a depth frame were captured together when their timestamps are equal.
// All pixels, and the intrinsics, are in the sensor's native orientation, unrotated and unmirrored; each frame records how the phone was held.
// Intrinsics fx,fy,cx,cy are per frame and per stream, each in its own stream's pixels; they are empty on a dropped row, and on a color row whose frame came without them.
// The depth comes from metadata.json's depth_source: "avfoundation_truedepth" (front: the TrueDepth camera through AVFoundation, color and depth from separate outputs) or "arkit_scene_depth" (rear: ARKit's LiDAR scene depth, not its temporally smoothed variant, with color and depth from the same ARFrame and so always at the same timestamp).
//
// The archive (format_version 5):
//   color.mov       HEVC color video; its n-th frame is the row with index n in color.csv. Its display transform is the first frame's upright rotation, so players show it upright.
//   color.csv       one row per color frame delivered or dropped, with the frame's intrinsics in color-frame pixels
//   depth.bin       depth maps exactly as the source delivered them (filtered by Apple only when metadata.json's depth_filtering_enabled), concatenated with no header: map n occupies bytes [n*size, (n+1)*size), size = depth_width*depth_height*depth_bytes_per_pixel, rows tightly packed, little-endian, pixel type depth_pixel_format ("fdep" Float32 metres, "hdep" Float16 metres); NaN or 0 marks a pixel without a reading
//   depth8_h264_w512.mov, depth8_h264_w480_stridewidth.mov, depth8_h264_w480.mov   avfoundation_truedepth only: the depth maps again, as three commits of an earlier app encoded them (see Depth8Track and metadata.json's depth8_h264), for ablations; the n-th sample is depth map n, at depth.csv's timestamp minus the first depth map's
//   confidence.bin  arkit_scene_depth only: one map per depth map, in depth.bin's order and layout, UInt8 per pixel, ARConfidenceLevel 0 low, 1 medium, 2 high
//   depth.csv       one row per depth map delivered or dropped, with its intrinsics in depth-map pixels, scaled from the color camera's intrinsics (the depth is registered to the color camera): avfoundation_truedepth from the calibration's intrinsic reference dimensions, arkit_scene_depth from the captured image's; filtered/accuracy/quality are AVDepthData's, and "0"/"absolute"/empty for ARKit; bytes_per_row is the delivered map's row stride, which depth.bin drops; arkit_scene_depth rows also carry the tracking state and the 4x4 camera-to-world pose pose_00..pose_33, row-major, in metadata.json's pose_convention
//   metadata.json   id, name, duration, device, depth source, formats and frame rate, conventions, the first depth map's calibration at the intrinsic reference dimensions, counts, whether it was recovered after the app stopped, the color video's error if its writer failed, and, for avfoundation_truedepth, how the 8-bit depth tracks were made (depth8_h264) and their writers' error (depth8_h264_error)
//
// The work directory holds everything packing needs, so a directory left by a closed app or a failed pack is packed at the next launch:
//   start.json        metadata known when recording starts: camera, start time, device, formats, conventions
//   calibration.json  the first depth map's calibration, once one has arrived
//   color.mov, color.csv, depth.bin, confidence.bin, depth8_h264_*.mov, depth.csv   written as the frames arrive; the movies are fragmented every second, so each plays up to its last fragment if its writer never finishes
//   sidecar.json      the recording's id, name and duration, fixed when packing begins; a pack that finds it resumes
//   archive.tar.part  the archive being built; each file is deleted once it is in
final class Recording {
    static var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    private static var workRoot: URL { documents.appendingPathComponent("work", isDirectory: true) }
    private static let archived = ["color.mov", "depth.bin", "color.csv", "depth.csv", "metadata.json"]
    private static let confidenceFile = "confidence.bin"

    static let intrinsicsColumns = "fx,fy,cx,cy"
    static let orientationColumns = "upright_rotation_deg,gravity_x,gravity_y,gravity_z,gravity_ts"
    static let colorHeader = "index,timestamp,dropped," + intrinsicsColumns + "," + orientationColumns
    static let poseColumns = "tracking," + (0..<4).flatMap { r in (0..<4).map { c in "pose_\(r)\(c)" } }.joined(separator: ",")
    static let depthHeader = "index,timestamp,dropped,filtered,accuracy,quality," + intrinsicsColumns + "," + orientationColumns + "," + poseColumns + ",bytes_per_row"

    private let directory: URL
    private let format: StreamFormat
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let colorTable: FileHandle
    private let depthTable: FileHandle
    private let depthHandle: FileHandle
    // Present when the source delivers confidence.
    private let confidenceHandle: FileHandle?
    private let fileQueue = DispatchQueue(label: "recording.files")
    // The front camera's 8-bit depth tracks, encoded on their own queue; empty for the rear camera.
    private let depth8: [Depth8Track]
    private let depth8Queue = DispatchQueue(label: "recording.depth8")
    // Entered until stop() has finished the videos, so packing waits for them.
    private let stopped = DispatchGroup()
    private var colorVideoError: String?

    // Owned by fileQueue: the first failed write, after which nothing more is written.
    private var fileError: Error?

    // Owned by the capture data queue.
    private var colorCount = 0
    private var depthCount = 0
    private var hasCalibration = false
    // The first depth map's time, time zero of the 8-bit depth tracks.
    private var depth8Start: CMTime?

    init(camera: DepthCamera, format: StreamFormat) throws {
        self.format = format
        directory = Self.workRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var systemInfo = utsname()
        uname(&systemInfo)
        if camera == .front {
            precondition(format.depthPixelFormat == kCVPixelFormatType_DepthFloat32 && format.depthWidth > format.depthHeight,
                         "8-bit depth tracks need a landscape Float32 depth map, not \(format.depthWidth)×\(format.depthHeight) \(fourCC(format.depthPixelFormat))")
            // Turned into portrait, the map is depthHeight wide; the earlier app's first buffer was the next power of two wide.
            let width = format.depthHeight
            let powerOfTwo = 1 << (Int.bitWidth - (width - 1).leadingZeroBitCount)
            let track = { [directory] (file: String, reproduces: String, sourceRows: Depth8Track.Rows, bufferWidth: Int, bufferRows: Depth8Track.Rows) in
                try Depth8Track(directory: directory, file: file, reproduces: reproduces, width: width, height: format.depthWidth, sourceRows: sourceRows, bufferWidth: bufferWidth, bufferRows: bufferRows)
            }
            depth8 = try [
                track("depth8_h264_w\(powerOfTwo).mov", "9627f38: buffer the next power of two wide, rows a width apart in the map and the buffer", .width, powerOfTwo, .width),
                track("depth8_h264_w\(width)_stridewidth.mov", "ddeadac: buffer as wide as the map, rows a width apart in the map and the buffer", .width, width, .width),
                track("depth8_h264_w\(width).mov", "aa3e5ee: buffer as wide as the map, rows bytes-per-row apart in the map and the buffer", .bytesPerRow, width, .bytesPerRow),
            ]
        } else {
            depth8 = []
        }

        var start = format.describe()
        start["camera"] = camera.rawValue
        start["start_time_utc"] = ISO8601DateFormatter().string(from: Date())
        if !depth8.isEmpty {
            start["depth8_h264"] = [
                "tracks": depth8.map(\.described),
                "range_m": Depth8Track.rangeMetres,
                "layout": Depth8Track.layout,
                "pixel_mapping": Depth8Track.pixelMapping,
                "description": "each depth map as delivered, its rows read bytes_per_row apart (depth.bin's map) or, for source_rows width, depth_width floats apart from the start of the delivered buffer (the same map unless depth.csv's bytes_per_row exceeds depth_width * 4), laid out as the earlier app's .portrait, mirrored front depth connection delivered it (layout, pixel_mapping), quantized as code = UInt8(min(max(z / range_m, 0), 1) * 255) in Float32, truncated, with NaN and z <= 0 → 0, written into a zeroed OneComponent8 buffer buffer_width wide whose rows are buffer_bytes_per_row bytes apart, row j at byte j * buffer_row_stride_bytes, and encoded by the phone's H.264 encoder at encoded_width × encoded_height with its default settings; the n-th sample is depth map n at depth.csv's timestamp minus the first depth map's; decode as code / 255 * range_m metres, 0 meaning no reading",
            ]
        }
        start["device_model"] = withUnsafeBytes(of: &systemInfo.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        start["system_version"] = UIDevice.current.systemVersion
        start["timestamp_clock"] = "host time (CMClockGetHostTimeClock), seconds; shared by color.csv, depth.csv and gravity_ts"
        start["orientation_convention"] = "pixels and intrinsics are in the sensor's native orientation, unrotated and unmirrored; rotating a frame clockwise by its upright_rotation_deg makes it upright (horizon-level); gravity_x/y/z is CoreMotion gravity in g in the phone's device frame (x right, y toward the top of the phone held in portrait, z out of the screen)"
        try JSONSerialization.data(withJSONObject: start, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("start.json"))

        writer = try AVAssetWriter(outputURL: directory.appendingPathComponent("color.mov"), fileType: .mov)
        writer.movieFragmentInterval = CMTime(value: 1, timescale: 1)
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: format.colorWidth,
            AVVideoHeightKey: format.colorHeight,
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
        confidenceHandle = format.confidencePixelFormat == nil ? nil : try Self.create(directory.appendingPathComponent(Self.confidenceFile), Data())
        stopped.enter()
        depth8.forEach { _ in stopped.enter() }
    }

    private static func create(_ url: URL, _ contents: Data) throws -> FileHandle {
        guard FileManager.default.createFile(atPath: url.path, contents: contents) else { throw RecorderError("cannot create \(url.lastPathComponent)") }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        return handle
    }

    // The frame calls below, and stop(), run on the capture data queue.

    // Returns whether the frame went into the video; a frame the writer does not take is recorded as dropped.
    func appendColor(_ buffer: CMSampleBuffer, intrinsics: matrix_float3x3?, orientation: Orientation) -> Bool {
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
        append([String(colorCount), seconds(time), ""] + Self.columns(intrinsics) + [Self.columns(orientation)], to: colorTable)
        colorCount += 1
        return true
    }

    func recordDroppedColor(at time: CMTime, reason: String) {
        append(["-1", seconds(time), reason] + Array(repeating: "", count: 4) + [Self.columns(nil)], to: colorTable)
    }

    func appendDepth(_ depth: DepthSample, orientation: Orientation) {
        let (bytes, bytesPerRow) = writeMap(depth.map, width: format.depthWidth, height: format.depthHeight, pixelFormat: format.depthPixelFormat, bytesPerPixel: format.depthBytesPerPixel, to: depthHandle)
        if !depth8.isEmpty {
            let start = depth8Start ?? depth.time
            depth8Start = start
            let time = CMTimeSubtract(depth.time, start)
            // Read depth_width floats apart from the buffer's start, the rows are the packed map's unless the buffer pads them.
            let padded = bytesPerRow != format.depthWidth * 4
            let misread = padded ? Self.contiguous(depth.map, count: bytes.count) : bytes
            depth8Queue.async { [depth8, format] in
                let codes = Depth8Track.codes(bytes, mapWidth: format.depthWidth, mapHeight: format.depthHeight)
                let misreadCodes = padded ? Depth8Track.codes(misread, mapWidth: format.depthWidth, mapHeight: format.depthHeight) : codes
                depth8.forEach { $0.append($0.sourceRows == .width ? misreadCodes : codes, at: time) }
            }
        }
        if let confidenceHandle, let confidencePixelFormat = format.confidencePixelFormat {
            guard let confidence = depth.confidence else { preconditionFailure("depth map at \(seconds(depth.time)) s came without its confidence map") }
            writeMap(confidence, width: format.depthWidth, height: format.depthHeight, pixelFormat: confidencePixelFormat, bytesPerPixel: 1, to: confidenceHandle)
        } else {
            precondition(depth.confidence == nil, "confidence map from a source whose format has none")
        }
        if !hasCalibration, let calibration = depth.calibration {
            hasCalibration = true
            let described = calibration()
            perform { [directory] in
                try JSONSerialization.data(withJSONObject: described, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("calibration.json"))
            }
        }
        append([String(depthCount), seconds(depth.time), "", depth.filtered, depth.accuracy, depth.quality]
               + Self.columns(depth.intrinsics) + [Self.columns(orientation), Self.columns(tracking: depth.tracking, pose: depth.pose), String(bytesPerRow)], to: depthTable)
        depthCount += 1
    }

    func recordDroppedDepth(at time: CMTime, reason: String) {
        append(["-1", seconds(time), reason] + Array(repeating: "", count: 7) + [Self.columns(nil), Self.columns(tracking: nil, pose: nil), ""], to: depthTable)
    }

    // Copies the map's rows without their padding, then writes them off the capture queue; returns the copy and the map's bytes per row.
    @discardableResult
    private func writeMap(_ map: CVPixelBuffer, width: Int, height: Int, pixelFormat: OSType, bytesPerPixel: Int, to handle: FileHandle) -> (Data, Int) {
        precondition(CVPixelBufferGetWidth(map) == width && CVPixelBufferGetHeight(map) == height && CVPixelBufferGetPixelFormatType(map) == pixelFormat,
                     "\(CVPixelBufferGetWidth(map))×\(CVPixelBufferGetHeight(map)) \(fourCC(CVPixelBufferGetPixelFormatType(map))) map differs from the stream format's \(width)×\(height) \(fourCC(pixelFormat))")
        let rowBytes = width * bytesPerPixel
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
        perform { try handle.write(contentsOf: bytes) }
        return (bytes, bytesPerRow)
    }

    // The first count bytes of a buffer, row padding and all.
    private static func contiguous(_ map: CVPixelBuffer, count: Int) -> Data {
        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        precondition(CVPixelBufferGetDataSize(map) >= count, "a \(CVPixelBufferGetDataSize(map))-byte buffer has no \(count) bytes")
        return Data(bytes: CVPixelBufferGetBaseAddress(map)!, count: count)
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

    // Ends the recording at this moment; the videos finish in the background, the 8-bit depth tracks once their queued maps are in.
    func stop() {
        depth8Queue.async { [depth8, stopped] in
            depth8.forEach { $0.finish { stopped.leave() } }
        }
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
                for handle in [colorTable, depthTable, depthHandle, confidenceHandle].compactMap({ $0 }) { try handle.close() }
                if let fileError { throw fileError }
                let depth8Errors = depth8.compactMap { track in track.error.map { "\(track.file): \($0)" } }
                return try Self.pack(directory, userName: userName, colorVideoError: colorVideoError, depth8Error: depth8Errors.isEmpty ? nil : depth8Errors.joined(separator: "; "), recovered: false)
            })
        }
    }

    // Work directories of recordings that were never packed.
    static func leftovers() -> [URL] {
        // Documents/work does not exist before the first recording.
        (try? FileManager.default.contentsOfDirectory(at: workRoot, includingPropertiesForKeys: nil)) ?? []
    }

    // Packs a work directory into Documents/<id>.tar with its sidecar Documents/<id>.json and removes the directory, resuming a pack that was cut short. Returns nil, removing the directory, when a stream has no frames; a failed pack leaves the directory to be packed at the next launch, and its error names the directory.
    static func pack(_ directory: URL, userName: String?, colorVideoError: String?, depth8Error: String?, recovered: Bool) throws -> RecordingInfo? {
        do {
            return try packWorkDirectory(directory, userName: userName, colorVideoError: colorVideoError, depth8Error: depth8Error, recovered: recovered)
        } catch {
            throw RecorderError("work/\(directory.lastPathComponent): \(error.localizedDescription)")
        }
    }

    private static func packWorkDirectory(_ directory: URL, userName: String?, colorVideoError: String?, depth8Error: String?, recovered: Bool) throws -> RecordingInfo? {
        let pending = directory.appendingPathComponent("sidecar.json")
        if !FileManager.default.fileExists(atPath: pending.path) {
            guard let info = try writeMetadata(directory, userName: userName, colorVideoError: colorVideoError, depth8Error: depth8Error, recovered: recovered) else {
                try FileManager.default.removeItem(at: directory)
                return nil
            }
            try info.write(to: pending)
        }
        let info = try RecordingInfo.load(pending)
        if !FileManager.default.fileExists(atPath: info.tar.path) {
            let part = directory.appendingPathComponent("archive.tar.part")
            let start = try Self.start(directory)
            let files = archived + (start.confidenceBytesPerPixel == nil ? [] : [confidenceFile]) + (start.depth8H264?.tracks.map(\.file) ?? [])
            try Tar.pack(files.map { directory.appendingPathComponent($0) }, root: info.id, into: part)
            try info.write(to: info.sidecar)
            try FileManager.default.moveItem(at: part, to: info.tar)
        }
        try FileManager.default.removeItem(at: directory)
        return info
    }

    // The fields of start.json that packing relies on.
    private struct Start: Decodable {
        let camera: DepthCamera
        let startTimeUtc: Date
        let depthWidth: Int
        let depthHeight: Int
        let depthBytesPerPixel: Int
        // Present when the source delivers confidence.
        let confidenceBytesPerPixel: Int?
        let depthFilteringEnabled: Bool
        // Present for the front camera, which writes 8-bit depth tracks.
        let depth8H264: Depth8?

        struct Depth8: Decodable {
            struct Track: Decodable { let file: String }
            let tracks: [Track]
        }
    }

    private static func start(_ directory: URL) throws -> Start {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Start.self, from: Data(contentsOf: directory.appendingPathComponent("start.json")))
    }

    // Writes metadata.json from start.json, calibration.json and the tables, and returns the recording's sidecar; nil when a stream has no frames.
    private static func writeMetadata(_ directory: URL, userName: String?, colorVideoError: String?, depth8Error: String?, recovered: Bool) throws -> RecordingInfo? {
        let file = { (name: String) in directory.appendingPathComponent(name) }
        let start = try start(directory)
        guard var metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: file("start.json"))) as? [String: Any] else { throw RecorderError("start.json is not an object") }

        var color = try Table(contentsOf: file("color.csv"))
        let depth = try Table(contentsOf: file("depth.csv"))
        // A writer that did not finish, because the app was closed or the writer failed, leaves color.mov holding only the frames up to its last fragment.
        if recovered || colorVideoError != nil {
            let movieFrames = try videoFrameCount(file("color.mov"))
            guard movieFrames <= color.frames else { throw RecorderError("color.mov holds \(movieFrames) frames but color.csv only \(color.frames)") }
            color = color.dropping(from: movieFrames, reason: recovered ? "lost_in_crash" : "lost_in_video_failure")
            try color.text.write(to: file("color.csv"), atomically: true, encoding: .utf8)
        }
        guard color.frames > 0, depth.frames > 0 else { return nil }

        // A depth map written just before the app was closed can lack its row.
        let bytesPerFrame = start.depthWidth * start.depthHeight * start.depthBytesPerPixel
        try truncate(file("depth.bin"), toMaps: depth.frames, of: bytesPerFrame)
        if let confidenceBytesPerPixel = start.confidenceBytesPerPixel {
            try truncate(file(confidenceFile), toMaps: depth.frames, of: start.depthWidth * start.depthHeight * confidenceBytesPerPixel)
        }

        // An unnamed recording is named by its start date and time, its camera and its depth configuration.
        let config = depthConfig(start.camera, filtered: start.depthFilteringEnabled)
        let info = RecordingInfo(id: id(start.startTimeUtc, start.camera, config: config.id, userName), name: userName ?? "\(formatted(start.startTimeUtc, "yyyy-MM-dd HH:mm:ss")) \(config.name)",
                                 namedByUser: userName != nil, startTime: start.startTimeUtc, durationSeconds: max(color.last, depth.last) - min(color.first, depth.first),
                                 camera: start.camera, uploaded: false, colorVideoError: colorVideoError)
        metadata["format_version"] = 5
        metadata["id"] = info.id
        metadata["name"] = info.name
        metadata["named_by_user"] = info.namedByUser
        metadata["duration_s"] = info.durationSeconds
        metadata["recovered"] = recovered
        metadata["color_video_error"] = colorVideoError ?? NSNull()
        metadata["depth8_h264_error"] = depth8Error ?? NSNull()
        metadata["color_frames"] = color.frames
        metadata["depth_frames"] = depth.frames
        metadata["depth_bytes_per_frame"] = bytesPerFrame
        metadata["depth_calibration_first_frame"] = FileManager.default.fileExists(atPath: file("calibration.json").path)
            ? try JSONSerialization.jsonObject(with: Data(contentsOf: file("calibration.json"))) : NSNull()
        try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys]).write(to: file("metadata.json"))
        return info
    }

    // Cuts a file of maps to its first count maps, the ones with a depth.csv row.
    private static func truncate(_ url: URL, toMaps count: Int, of bytesPerMap: Int) throws {
        let handle = try FileHandle(forWritingTo: url)
        guard try handle.seekToEnd() >= UInt64(count * bytesPerMap) else { throw RecorderError("\(url.lastPathComponent) holds fewer maps than depth.csv") }
        try handle.truncate(atOffset: UInt64(count * bytesPerMap))
        try handle.close()
    }

    // The number of frames in a movie, counted from its samples without decoding them.
    private static func videoFrameCount(_ movie: URL) throws -> Int {
        let asset = AVURLAsset(url: movie)
        let loaded = DispatchSemaphore(value: 0)
        var tracks: Result<[AVAssetTrack], Error> = .failure(RecorderError("\(movie.lastPathComponent) did not load"))
        asset.loadTracks(withMediaType: .video) { found, error in
            tracks = found.map { .success($0) } ?? .failure(error ?? RecorderError("\(movie.lastPathComponent) has no tracks"))
            loaded.signal()
        }
        loaded.wait()
        guard let track = try tracks.get().first else { throw RecorderError("\(movie.lastPathComponent) has no video track") }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? RecorderError("cannot read \(movie.lastPathComponent)") }
        var frames = 0
        while let sample = output.copyNextSampleBuffer() { frames += CMSampleBufferGetNumSamples(sample) }
        guard reader.status == .completed else { throw reader.error ?? RecorderError("reading \(movie.lastPathComponent) stopped early") }
        return frames
    }

    // The depth configuration, as the id spells it and as the default name says it: filteroff or filteron for the front camera, arkit for the rear.
    private static func depthConfig(_ camera: DepthCamera, filtered: Bool) -> (id: String, name: String) {
        switch camera {
        case .front: return filtered ? ("filteron", "Front filter on") : ("filteroff", "Front filter off")
        case .rear:
            precondition(!filtered, "a rear recording with its depth filtered")
            return ("arkit", "Rear ARKit")
        }
    }

    // rgbd_<start>_<camera>_<config>, then the user's name, if given, reduced to [A-Za-z0-9_-] and at most 40 characters.
    private static func id(_ startTime: Date, _ camera: DepthCamera, config: String, _ userName: String?) -> String {
        let base = "rgbd_\(formatted(startTime, "yyyyMMdd_HHmmss"))_\(camera.rawValue)_\(config)"
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

    // fx, fy, cx, cy of an intrinsic matrix; empty when the frame came without one.
    private static func columns(_ k: matrix_float3x3?) -> [String] {
        guard let k else { return ["", "", "", ""] }
        return [k.columns.0.x, k.columns.1.y, k.columns.2.x, k.columns.2.y].map { String($0) }
    }

    // The tracking state and the pose, row-major; empty for a source without tracking and on a dropped row.
    private static func columns(tracking: String?, pose: simd_float4x4?) -> String {
        guard let tracking, let pose else {
            precondition(tracking == nil && pose == nil, "a pose without its tracking state, or the reverse")
            return String(repeating: ",", count: 16)
        }
        let m = [pose.columns.0, pose.columns.1, pose.columns.2, pose.columns.3]
        return ([tracking] + (0..<4).flatMap { r in (0..<4).map { c in String(m[c][r]) } }).joined(separator: ",")
    }

    // A dropped frame has no orientation.
    private static func columns(_ o: Orientation?) -> String {
        guard let o else { return ",,,," }
        guard let g = o.gravity, let t = o.gravityTime else { return "\(o.uprightRotationDegrees),,,," }
        return [String(o.uprightRotationDegrees), String(format: "%.5f", g.x), String(format: "%.5f", g.y), String(format: "%.5f", g.z), String(format: "%.9f", t)].joined(separator: ",")
    }
}

private func seconds(_ time: CMTime) -> String {
    String(format: "%.9f", CMTimeGetSeconds(time))
}
