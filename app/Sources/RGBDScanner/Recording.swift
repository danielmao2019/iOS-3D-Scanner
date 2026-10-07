import CoreMedia
import CryptoKit
import Foundation
import UIKit
import simd

// One recording, captured into a work directory Documents/work/<uuid>/ and, once it has a name, finished by renaming that directory to Documents/<id>/, which then holds exactly the archive's members and recording.json, and, once its upload reaches it, manifest.json. Each .bin member is hashed (SHA-256) from its bytes in memory as they are written, the other members when the recording finishes, and recording.json records every member's size and hash, so uploading (Uploader) sends the members one by one with their hashes and the receiver assembles the archive from them.
//
// metadata.json's camera says where the frames come from: "front" is the TrueDepth camera through AVFoundation (depth_source "avfoundation_truedepth"), color and depth from separate outputs at one frame rate; "rear" is the LiDAR camera through ARKit world tracking (depth_source "arkit_scene_depth"), the color image, its pose, the depth and its confidence from one ARFrame and so always at one timestamp. Depth is never filtered (depth_filtering_enabled false), and the lens autofocuses wherever it can (metadata.json's focus: autofocus or fixed).
// The two streams are recorded independently, each frame with its own capture timestamp (seconds, host clock); a color frame and a depth frame were captured together when their timestamps are equal.
// All pixels, the intrinsics and the poses' camera frame are in the sensor's native orientation, unrotated and unmirrored; each frame records how the phone was held.
// Intrinsics fx,fy,cx,cy are per frame and per stream, each in its own stream's pixels, as metadata.json's intrinsics_convention says; they are empty on a dropped row, and on a delivered row whose frame came without them.
// A dropped row is -1, the timestamp and why the frame was dropped (e.g. late, out_of_buffers, writer_busy, no_scene_depth), every other cell empty.
//
// The archive (format_version "4.7", the version of the app that wrote it, <major>.<minor>, the major the app version (v4) and the minor naming the app build; laid out as in 4.0 but for color.csv's exposure_duration_s, lens_position and received_ts, which 4.3 added), its members under <id>/:
//   color.bin          every delivered color frame exactly as the camera delivered it, uncompressed, with no header: the frame with color.csv index n occupies bytes [n*color_bytes_per_frame, (n+1)*color_bytes_per_frame), color_bytes_per_frame = color_width*color_height*3/2; each is "420f", 8-bit full-range YCbCr 4:2:0, stored as its luma plane, color_height rows of color_width bytes (a Y byte per pixel), then its CbCr plane, color_height/2 rows of color_width bytes (a Cb, Cr byte pair per 2×2 pixels), rows tightly packed; its RGB is through color_ycbcr_matrix
//   color.csv          one row per color frame delivered or dropped: index,timestamp,dropped,fx,fy,cx,cy,upright_rotation_deg,gravity_x,gravity_y,gravity_z,gravity_ts,exposure_duration_s,lens_position,received_ts, then, for the rear, tracking_state (normal, not_available or limited_<reason>) and world_from_camera_00 ... world_from_camera_23, rows 0-2 of ARCamera.transform as metadata.json's pose_convention says; exposure_duration_s is the frame's own exposure time in seconds, lens_position the capture device's lensPosition (0 to 1) and received_ts the host-clock seconds at which the app received the frame, the last two read when the frame reached the app and so later than its exposure by the capture pipeline's latency, as metadata.json's exposure_lens_arrival_convention says
//   depth.bin          depth maps exactly as delivered, concatenated with no header: map n occupies bytes [n*depth_bytes_per_frame, (n+1)*depth_bytes_per_frame), depth_bytes_per_frame = depth_width*depth_height*depth_bytes_per_pixel, rows tightly packed, little-endian, pixel type depth_pixel_format ("fdep" Float32 metres, "hdep" Float16 metres); NaN or 0 marks a pixel without a reading
//   depth.csv          one row per depth map delivered or dropped: index,timestamp,dropped, then, for the front, filtered,accuracy,quality (AVDepthData's isDepthDataFiltered 1 or 0, depthDataAccuracy absolute or relative, depthDataQuality high or low), then fx,fy,cx,cy,upright_rotation_deg,gravity_x,gravity_y,gravity_z,gravity_ts,bytes_per_row (the delivered map's row stride, which depth.bin drops)
//   confidence.bin     rear only: one map per depth map, in depth.bin's order and layout, UInt8 per pixel, ARConfidenceLevel 0 low, 1 medium, 2 high
//   calibration.jsonl  front only: one line per delivered depth map, in depth.csv's order, {"index": n, "timestamp": t, "calibration": c}, n and t the map's depth.csv index and timestamp, c its full AVCameraCalibrationData, or null when it came without one
//   metadata.json      id, name, duration, device, camera, depth source, formats and frame rate, focus, conventions, counts, and whether it was recovered after the app stopped
//
// A frame's bytes are queued for writing before its row, so every .bin and calibration.jsonl hold at least the frames that have a row; a color frame whose copy would push the bytes waiting to be written above maxQueuedBytes is dropped as writer_busy.
// The work directory holds everything finishing needs, so a directory left by a closed app or a failed finish is finished at the next launch, each file cut to the frames that have a row:
//   start.json        metadata known when recording starts: camera, start time, device, formats, conventions; removed once recording.json is written
//   color.bin, color.csv, depth.bin, depth.csv, confidence.bin (rear), calibration.jsonl (front)   written as the frames arrive
//   metadata.json     written when finishing begins, from start.json and the tables
//   recording.json    the recording's RecordingInfo with every member's size and SHA-256, written once metadata.json is; a finish that finds it only removes start.json and renames the directory
// A recording recovered at the next launch kept no hash, so its members are hashed by reading them when it is finished; so are those of a recording apps 4.1 to 4.5 finished, whose recording.json lists no members, when this app first finds it: the only times a recording's files are read back.
final class Recording {
    static var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    private static var workRoot: URL { documents.appendingPathComponent("work", isDirectory: true) }
    // The bytes waiting to be written and hashed stay within this: about 29 front or 129 rear color frames.
    private static let maxQueuedBytes = 512 << 20

    private static let intrinsicsColumns = "fx,fy,cx,cy"
    private static let orientationColumns = "upright_rotation_deg,gravity_x,gravity_y,gravity_z,gravity_ts"
    // A color frame's own exposure time, its capture device's lens position and when the app received it.
    private static let exposureLensArrivalColumns = "exposure_duration_s,lens_position,received_ts"
    // ARKit's tracking state and rows 0-2 of ARCamera.transform, row-major.
    private static let poseColumns = "tracking_state," + (0..<3).flatMap { row in (0..<4).map { column in "world_from_camera_\(row)\(column)" } }.joined(separator: ",")

    private let directory: URL
    private let format: StreamFormat
    private let colorFile: FramesFile
    private let colorTable: FileHandle
    private let depthFile: FramesFile
    private let depthTable: FileHandle
    // The rear's confidence.bin.
    private let confidenceFile: FramesFile?
    // The front's calibration.jsonl.
    private let calibrationHandle: FileHandle?
    // The column counts of color.csv and depth.csv, which differ by camera; every row has exactly these.
    private let colorColumns: Int
    private let depthColumns: Int
    // Each write's autoreleased memory is released as soon as it is written: a front recording writes about 0.55 GB a second.
    private let fileQueue = DispatchQueue(label: "recording.files", autoreleaseFrequency: .workItem)
    // Hashes each frame's bytes beside fileQueue's write of them.
    private let hashQueue = DispatchQueue(label: "recording.hashes", autoreleaseFrequency: .workItem)
    // Under bufferLock: the bytes of the frames queued and not yet both written and hashed, and the color buffers free for the next frame, each colorBytesPerFrame long; a color buffer goes back on the free list once it is written and hashed, so the bound on queuedBytes bounds how many exist, and all are freed when the files are closed.
    private let bufferLock = NSLock()
    private var queuedBytes = 0
    private var freeColorBuffers: [UnsafeMutableRawPointer] = []
    // Entered for each frame's bytes when they are queued, left once they are written, hashed and released; finishing waits for it to empty.
    private let framesInFlight = DispatchGroup()

    // Owned by fileQueue: the first failed write, after which nothing more is written.
    private var fileError: Error?

    // Owned by the capture data queue.
    private var colorCount = 0
    private var depthCount = 0

    init(camera: DepthCamera, format: StreamFormat) throws {
        precondition((format.confidencePixelFormat != nil) == (camera == .rear), "a \(camera.rawValue) recording of a stream \(format.confidencePixelFormat == nil ? "without" : "with") confidence")
        self.format = format
        directory = Self.workRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var systemInfo = utsname()
        uname(&systemInfo)
        var start = format.describe()
        start["camera"] = camera.rawValue
        start["depth_source"] = camera.depthSource
        start["start_time_utc"] = ISO8601DateFormatter().string(from: Date())
        start["device_model"] = withUnsafeBytes(of: &systemInfo.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        start["system_version"] = UIDevice.current.systemVersion
        start["timestamp_clock"] = "host time (CMClockGetHostTimeClock), seconds; shared by color.csv, depth.csv and gravity_ts"
        start["orientation_convention"] = "pixels and intrinsics are in the sensor's native orientation, unrotated and unmirrored; rotating a frame clockwise by its upright_rotation_deg makes it upright (horizon-level); gravity_x/y/z is CoreMotion gravity in g in the phone's device frame (x right, y toward the top of the phone held in portrait, z out of the screen)"
        try JSONSerialization.data(withJSONObject: start, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("start.json"))

        let colorHeader = "index,timestamp,dropped," + Self.intrinsicsColumns + "," + Self.orientationColumns + "," + Self.exposureLensArrivalColumns + (camera == .rear ? "," + Self.poseColumns : "")
        let depthHeader = "index,timestamp,dropped," + (camera == .front ? "filtered,accuracy,quality," : "") + Self.intrinsicsColumns + "," + Self.orientationColumns + ",bytes_per_row"
        colorColumns = colorHeader.split(separator: ",").count
        depthColumns = depthHeader.split(separator: ",").count
        colorFile = try FramesFile(directory, "color.bin")
        colorTable = try Self.create(directory.appendingPathComponent("color.csv"), Data((colorHeader + "\n").utf8))
        depthFile = try FramesFile(directory, "depth.bin")
        depthTable = try Self.create(directory.appendingPathComponent("depth.csv"), Data((depthHeader + "\n").utf8))
        confidenceFile = camera == .rear ? try FramesFile(directory, "confidence.bin") : nil
        calibrationHandle = camera == .front ? try Self.create(directory.appendingPathComponent("calibration.jsonl"), Data()) : nil
    }

    private static func create(_ url: URL, _ contents: Data) throws -> FileHandle {
        guard FileManager.default.createFile(atPath: url.path, contents: contents) else { throw RecorderError("cannot create \(url.lastPathComponent)") }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        return handle
    }

    // A .bin file of frames, written past the page cache on fileQueue, with the size and SHA-256 of the bytes queued to it, added on hashQueue beside the writes.
    private final class FramesFile {
        let name: String
        let handle: FileHandle
        // Owned by hashQueue.
        var size = 0
        var hasher = SHA256()

        init(_ directory: URL, _ name: String) throws {
            self.name = name
            handle = try Recording.create(directory.appendingPathComponent(name), Data())
            // The frames are never read back while recording; caching 0.55 GB a second of them would only add a copy and memory pressure.
            guard fcntl(handle.fileDescriptor, F_NOCACHE, 1) != -1 else { throw RecorderError("cannot turn off caching of \(name): \(String(cString: strerror(errno)))") }
        }
    }

    // The frame calls below run on the capture data queue.

    // Returns whether the frame is written; a frame whose copy would push the bytes waiting to be written above maxQueuedBytes is recorded as dropped. Only the rear's frames come with a pose.
    func appendColor(_ color: ColorSample, orientation: Orientation) -> Bool {
        // Only this queue adds to queuedBytes, so the bound still holds once the frame is queued.
        guard bufferLock.withLock({ queuedBytes }) + format.colorBytesPerFrame <= Self.maxQueuedBytes else {
            recordDroppedColor(at: color.time, reason: "writer_busy")
            return false
        }
        writeColor(color.image)
        let exposureLensArrival = [String(format: "%.9f", color.exposureDuration), String(color.lensPosition), seconds(color.received)]
        append([String(colorCount), seconds(color.time), ""] + Self.cells(color.intrinsics) + Self.cells(orientation) + exposureLensArrival + Self.cells(color.pose), to: colorTable, columns: colorColumns)
        colorCount += 1
        return true
    }

    func recordDroppedColor(at time: CMTime, reason: String) {
        append(["-1", seconds(time), reason] + Array(repeating: "", count: colorColumns - 3), to: colorTable, columns: colorColumns)
    }

    func appendDepth(_ depth: DepthSample, orientation: Orientation) {
        let bytesPerRow = writeMap(depth.map, width: format.depthWidth, height: format.depthHeight, pixelFormat: format.depthPixelFormat, bytesPerPixel: format.depthBytesPerPixel, to: depthFile)
        if let confidenceFile, let confidencePixelFormat = format.confidencePixelFormat {
            guard let confidence = depth.confidence else { preconditionFailure("depth map at \(seconds(depth.time)) s came without its confidence map") }
            writeMap(confidence, width: format.depthWidth, height: format.depthHeight, pixelFormat: confidencePixelFormat, bytesPerPixel: 1, to: confidenceFile)
        } else {
            precondition(depth.confidence == nil, "confidence map from a source whose format has none")
        }
        if let calibrationHandle {
            writeCalibration(depth.calibration, index: depthCount, time: depth.time, to: calibrationHandle)
        } else {
            precondition(depth.calibration == nil, "calibration from the rear camera, which has none")
        }
        append([String(depthCount), seconds(depth.time), ""] + depth.sourceCells + Self.cells(depth.intrinsics) + Self.cells(orientation) + [String(bytesPerRow)], to: depthTable, columns: depthColumns)
        depthCount += 1
    }

    func recordDroppedDepth(at time: CMTime, reason: String) {
        append(["-1", seconds(time), reason] + Array(repeating: "", count: depthColumns - 3), to: depthTable, columns: depthColumns)
    }

    // Copies a 420f frame's planes without their row padding, the luma rows, then the CbCr rows, into a free color buffer, then writes and hashes the buffer as it is off the capture queue.
    private func writeColor(_ image: CVPixelBuffer) {
        let width = format.colorWidth, height = format.colorHeight
        precondition(CVPixelBufferGetPixelFormatType(image) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, "color frame is \(fourCC(CVPixelBufferGetPixelFormatType(image))), not 420f")
        precondition(CVPixelBufferGetWidthOfPlane(image, 0) == width && CVPixelBufferGetHeightOfPlane(image, 0) == height
                     && CVPixelBufferGetWidthOfPlane(image, 1) == width / 2 && CVPixelBufferGetHeightOfPlane(image, 1) == height / 2,
                     "a \(CVPixelBufferGetWidth(image))×\(CVPixelBufferGetHeight(image)) 420f frame differs from the stream format's \(width)×\(height)")
        // Plane 0 has a Y byte per pixel, plane 1 a Cb, Cr byte pair per 2 × 2 pixels, so a row of either is width bytes.
        let planeRows = [height, height / 2]
        let buffer = bufferLock.withLock { freeColorBuffers.popLast() } ?? newColorBuffer()
        CVPixelBufferLockBaseAddress(image, .readOnly)
        var offset = 0
        for (plane, rows) in planeRows.enumerated() {
            let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(image, plane)
            let base = CVPixelBufferGetBaseAddressOfPlane(image, plane)!
            for y in 0..<rows {
                memcpy(buffer.advanced(by: offset), base.advanced(by: y * bytesPerRow), width)
                offset += width
            }
        }
        CVPixelBufferUnlockBaseAddress(image, .readOnly)
        write(Data(bytesNoCopy: buffer, count: format.colorBytesPerFrame, deallocator: .none), to: colorFile, recycling: buffer)
    }

    // A color buffer aligned to iOS's 16 KiB pages, for the uncached write.
    private func newColorBuffer() -> UnsafeMutableRawPointer {
        var buffer: UnsafeMutableRawPointer?
        let status = posix_memalign(&buffer, 16384, format.colorBytesPerFrame)
        precondition(status == 0, "cannot allocate a \(format.colorBytesPerFrame)-byte color buffer: \(String(cString: strerror(status)))")
        return buffer!
    }

    // Copies the map's rows without their padding, then writes and hashes them off the capture queue; returns the map's bytes per row.
    @discardableResult
    private func writeMap(_ map: CVPixelBuffer, width: Int, height: Int, pixelFormat: OSType, bytesPerPixel: Int, to file: FramesFile) -> Int {
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
        write(bytes, to: file)
        return bytesPerRow
    }

    // Writes a depth map's calibration.jsonl line; its calibration is described and turned into JSON on the file queue, off the capture queue.
    private func writeCalibration(_ calibration: (() -> [String: Any])?, index: Int, time: CMTime, to handle: FileHandle) {
        let head = "{\"index\": \(index), \"timestamp\": \(seconds(time)), \"calibration\": "
        perform {
            let json = try calibration.map { try JSONSerialization.data(withJSONObject: $0(), options: [.sortedKeys]) } ?? Data("null".utf8)
            try handle.write(contentsOf: Data(head.utf8) + json + Data("}\n".utf8))
        }
    }

    private func append(_ row: [String], to table: FileHandle, columns: Int) {
        precondition(row.count == columns, "a row of \(row.count) cells in a table of \(columns) columns: \(row)")
        let line = Data((row.joined(separator: ",") + "\n").utf8)
        perform { try table.write(contentsOf: line) }
    }

    // Writes a frame's bytes to their file through perform and adds them to the file's hash on hashQueue, beside the write; they count in queuedBytes and framesInFlight, and the color buffer holding them, if any, goes back on the free list, once both are done.
    private func write(_ bytes: Data, to file: FramesFile, recycling colorBuffer: UnsafeMutableRawPointer? = nil) {
        let count = bytes.count
        bufferLock.withLock { queuedBytes += count }
        framesInFlight.enter()
        let done = DispatchGroup()
        perform(group: done) { try file.handle.write(contentsOf: bytes) }
        hashQueue.async(group: done) {
            file.hasher.update(data: bytes)
            file.size += count
        }
        done.notify(queue: fileQueue) { [self] in
            bufferLock.withLock {
                queuedBytes -= count
                if let colorBuffer { freeColorBuffers.append(colorBuffer) }
            }
            framesInFlight.leave()
        }
    }

    // Runs a file write on the file queue, in the order the writes were asked for, as part of group when one is given.
    private func perform(group: DispatchGroup? = nil, _ write: @escaping () throws -> Void) {
        fileQueue.async(group: group) { [self] in
            guard fileError == nil else { return }
            do { try write() } catch { fileError = error }
        }
    }

    // Once every frame's bytes are written, hashed and released, frees the color buffers, closes the files and finishes the recording with its .bin files' hashes; userName is nil when the user left it unnamed.
    func finish(userName: String?, completion: @escaping (Result<RecordingInfo?, Error>) -> Void) {
        // The tables' writes, queued while recording, are ahead of this on fileQueue, so they are in too.
        framesInFlight.notify(queue: fileQueue) { [self] in
            completion(Result {
                bufferLock.withLock {
                    freeColorBuffers.forEach { free($0) }
                    freeColorBuffers.removeAll()
                }
                for handle in [colorFile.handle, colorTable, depthFile.handle, depthTable, confidenceFile?.handle, calibrationHandle].compactMap({ $0 }) { try handle.close() }
                if let fileError { throw fileError }
                let hashes: [String: (size: Int, sha256: String)] = hashQueue.sync {
                    Dictionary(uniqueKeysWithValues: [colorFile, depthFile, confidenceFile].compactMap { $0 }.map { ($0.name, (size: $0.size, sha256: $0.hasher.finalize().hex)) })
                }
                return try Self.finish(directory, userName: userName, hashes: hashes)
            })
        }
    }

    // Work directories of recordings that were never finished.
    static func leftovers() -> [URL] {
        // Documents/work does not exist before the first recording.
        (try? FileManager.default.contentsOfDirectory(at: workRoot, includingPropertiesForKeys: nil)) ?? []
    }

    // Finishes, under its date and time, a work directory a closed app or a failed finish left; it kept no hash, so its members are hashed by reading them.
    static func recover(_ directory: URL) throws -> RecordingInfo? {
        try finish(directory, userName: nil, hashes: nil)
    }

    // The recordings apps 4.1 to 4.5 finished: their recording.json lists no members.
    static func withoutMembers() -> [URL] {
        let directories = (try? FileManager.default.contentsOfDirectory(at: documents, includingPropertiesForKeys: nil)) ?? []
        return directories.filter { listsNoMembers($0.appendingPathComponent(RecordingInfo.fileName)) }
    }

    // Whether recording.json exists and lists no members, as apps 4.1 to 4.5 wrote it.
    static func listsNoMembers(_ infoFile: URL) -> Bool {
        guard let data = try? Data(contentsOf: infoFile), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return object["members"] == nil
    }

    // Gives a recording apps 4.1 to 4.5 finished its members, each hashed by reading it and acknowledged when the recording was uploaded, rewriting its recording.json; it is otherwise as this app writes it.
    static func addMembers(_ directory: URL) throws -> RecordingInfo {
        // recording.json as apps 4.1 to 4.5 wrote it.
        struct Listed: Decodable {
            let id: String
            let name: String
            let namedByUser: Bool
            let startTime: Date
            let durationSeconds: Double
            let camera: DepthCamera
            let uploaded: Bool
        }
        let infoFile = directory.appendingPathComponent(RecordingInfo.fileName)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let listed = try decoder.decode(Listed.self, from: Data(contentsOf: infoFile))
        let members = try archiveMembers(listed.camera).map { member -> RecordingInfo.Member in
            let read = try hash(directory.appendingPathComponent(member))
            return RecordingInfo.Member(name: member, size: read.size, sha256: read.sha256, uploaded: listed.uploaded)
        }
        let info = RecordingInfo(id: listed.id, name: listed.name, namedByUser: listed.namedByUser, startTime: listed.startTime, durationSeconds: listed.durationSeconds, camera: listed.camera, members: members, uploaded: listed.uploaded)
        try info.write(to: infoFile)
        return info
    }

    // Finishes a work directory where it lies, copying none of its frames: writes metadata.json, cutting each file to the frames that have a row, and recording.json with every member's size and SHA-256, removes start.json and renames the directory to Documents/<id>/, resuming a finish that was cut short. hashes holds the .bin files' sizes and SHA-256s taken as they were written, and is nil for a recording recovered after the app stopped. Returns nil, removing the directory, when a stream has no frames; a failed finish leaves the directory to be finished at the next launch, and its error names the directory.
    private static func finish(_ directory: URL, userName: String?, hashes: [String: (size: Int, sha256: String)]?) throws -> RecordingInfo? {
        do {
            return try finishWorkDirectory(directory, userName: userName, hashes: hashes)
        } catch {
            throw RecorderError("work/\(directory.lastPathComponent): \(error.localizedDescription)")
        }
    }

    private static func finishWorkDirectory(_ directory: URL, userName: String?, hashes: [String: (size: Int, sha256: String)]?) throws -> RecordingInfo? {
        let infoFile = directory.appendingPathComponent(RecordingInfo.fileName)
        if !FileManager.default.fileExists(atPath: infoFile.path) {
            guard let info = try writeMetadata(directory, userName: userName, hashes: hashes) else {
                try FileManager.default.removeItem(at: directory)
                return nil
            }
            try info.write(to: infoFile)
        }
        let info = try RecordingInfo.load(infoFile)
        let start = directory.appendingPathComponent("start.json")
        if FileManager.default.fileExists(atPath: start.path) { try FileManager.default.removeItem(at: start) }
        try FileManager.default.moveItem(at: directory, to: info.directory)
        return info
    }

    // The fields of start.json that finishing relies on.
    private struct Start: Decodable {
        let camera: DepthCamera
        let startTimeUtc: Date
        let colorBytesPerFrame: Int
        let depthWidth: Int
        let depthHeight: Int
        let depthBytesPerFrame: Int
    }

    private static func start(_ directory: URL) throws -> Start {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Start.self, from: Data(contentsOf: directory.appendingPathComponent("start.json")))
    }

    // Writes metadata.json from start.json and the tables, cutting each file to the frames that have a row, and returns the recording's RecordingInfo with every member's size and SHA-256; nil when a stream has no frames. hashes is as finish takes it.
    private static func writeMetadata(_ directory: URL, userName: String?, hashes: [String: (size: Int, sha256: String)]?) throws -> RecordingInfo? {
        let file = { (name: String) in directory.appendingPathComponent(name) }
        let start = try start(directory)
        guard var metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: file("start.json"))) as? [String: Any] else { throw RecorderError("start.json is not an object") }

        let color = try Table(contentsOf: file("color.csv"))
        let depth = try Table(contentsOf: file("depth.csv"))
        guard color.frames > 0, depth.frames > 0 else { return nil }

        // A frame's bytes are written before its row, so a recording cut off by a closed app can hold frames without one.
        try truncate(file("color.bin"), toFrames: color.frames, of: start.colorBytesPerFrame)
        try truncate(file("depth.bin"), toFrames: depth.frames, of: start.depthBytesPerFrame)
        switch start.camera {
        case .front: try truncate(file("calibration.jsonl"), toLines: depth.frames)
        // One UInt8 per depth pixel.
        case .rear: try truncate(file("confidence.bin"), toFrames: depth.frames, of: start.depthWidth * start.depthHeight)
        }

        let id = id(start.startTimeUtc, start.camera, userName)
        // An unnamed recording is named by its start date and time and its camera.
        let name = userName ?? "\(formatted(start.startTimeUtc, "yyyy-MM-dd HH:mm:ss")) \(start.camera == .front ? "Front" : "Rear")"
        let duration = max(color.last, depth.last) - min(color.first, depth.first)
        metadata["format_version"] = "4.7"
        metadata["id"] = id
        metadata["name"] = name
        metadata["named_by_user"] = userName != nil
        metadata["duration_s"] = duration
        metadata["recovered"] = hashes == nil
        metadata["color_frames"] = color.frames
        metadata["depth_frames"] = depth.frames
        try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys]).write(to: file("metadata.json"))

        let members = try archiveMembers(start.camera).map { member -> RecordingInfo.Member in
            if let hashed = hashes?[member] {
                // Every frame of a recording the app stopped has its row, so cutting a .bin file to its rows leaves exactly the bytes hashed.
                guard try file(member).resourceValues(forKeys: [.fileSizeKey]).fileSize == hashed.size else { throw RecorderError("\(member) is not the \(hashed.size) bytes hashed as it was written") }
                return RecordingInfo.Member(name: member, size: hashed.size, sha256: hashed.sha256, uploaded: false)
            }
            let read = try hash(file(member))
            return RecordingInfo.Member(name: member, size: read.size, sha256: read.sha256, uploaded: false)
        }
        return RecordingInfo(id: id, name: name, namedByUser: userName != nil, startTime: start.startTimeUtc, durationSeconds: duration, camera: start.camera, members: members, uploaded: false)
    }

    // The archive's members in the order the archive holds them.
    private static func archiveMembers(_ camera: DepthCamera) -> [String] {
        ["color.bin", "depth.bin", "color.csv", "depth.csv", "metadata.json"] + (camera == .rear ? ["confidence.bin"] : ["calibration.jsonl"])
    }

    // A file's size and SHA-256, read back in chunks; each chunk is released before the next is read, as a file of several GB would otherwise stay in memory until iOS stops the app.
    private static func hash(_ url: URL) throws -> (size: Int, sha256: String) {
        let handle = try FileHandle(forReadingFrom: url)
        var hasher = SHA256()
        var size = 0
        while try autoreleasepool(invoking: { () throws -> Bool in
            guard let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty else { return false }
            hasher.update(data: chunk)
            size += chunk.count
            return true
        }) {}
        try handle.close()
        return (size, hasher.finalize().hex)
    }

    // Cuts a file of frames to its first count frames, the ones with a table row.
    private static func truncate(_ url: URL, toFrames count: Int, of bytesPerFrame: Int) throws {
        let handle = try FileHandle(forWritingTo: url)
        guard try handle.seekToEnd() >= UInt64(count * bytesPerFrame) else { throw RecorderError("\(url.lastPathComponent) holds fewer frames than its table") }
        try handle.truncate(atOffset: UInt64(count * bytesPerFrame))
        try handle.close()
    }

    // Cuts a file of lines to its first count lines, the ones with a table row.
    private static func truncate(_ url: URL, toLines count: Int) throws {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        var end = data.startIndex
        for _ in 0..<count {
            guard let newline = data[end...].firstIndex(of: UInt8(ascii: "\n")) else { throw RecorderError("\(url.lastPathComponent) holds fewer lines than its table") }
            end = newline + 1
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(end))
        try handle.close()
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

    // fx, fy, cx, cy of an intrinsic matrix; empty when the frame came without one.
    private static func cells(_ k: matrix_float3x3?) -> [String] {
        guard let k else { return ["", "", "", ""] }
        return [k.columns.0.x, k.columns.1.y, k.columns.2.x, k.columns.2.y].map { String($0) }
    }

    // upright_rotation_deg, gravity_x, gravity_y, gravity_z, gravity_ts; the gravity cells are empty before the first motion sample.
    private static func cells(_ o: Orientation) -> [String] {
        guard let g = o.gravity, let t = o.gravityTime else { return [String(o.uprightRotationDegrees), "", "", "", ""] }
        return [String(o.uprightRotationDegrees), String(format: "%.5f", g.x), String(format: "%.5f", g.y), String(format: "%.5f", g.z), String(format: "%.9f", t)]
    }

    // tracking_state, then world_from_camera_00 ... world_from_camera_23; none for the front, which has no pose.
    private static func cells(_ pose: Pose?) -> [String] {
        guard let pose else { return [] }
        // Row-major, while a simd matrix is indexed by column first.
        let t = pose.worldFromCamera
        return [pose.trackingState] + (0..<3).flatMap { row in (0..<4).map { column in String(t[column][row]) } }
    }
}

private func seconds(_ time: CMTime) -> String {
    String(format: "%.9f", CMTimeGetSeconds(time))
}

extension SHA256Digest {
    // As 64 lowercase hex characters, the way recording.json, the manifest and the receiver write a SHA-256.
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
