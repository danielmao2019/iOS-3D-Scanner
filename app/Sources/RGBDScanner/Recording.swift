import AVFoundation
import CoreMedia
import CryptoKit
import Foundation
import UIKit
import simd

// One recording, captured into a work directory Documents/work/<uuid>/ and, once it has a name, finished by renaming that directory to Documents/<id>/, which then holds the recording's JSON files and recording.json, and, once its upload reaches it, manifest.json. Each frame is encoded losslessly (FrameCodec) off the capture queue and written to its frames file's open segment in Documents/segments/<uuid>/; a segment is closed at the first frame boundary past segmentBytes, hashed (SHA-256) from its bytes in memory as they were written, recorded in segments.jsonl and handed to onSegment, which uploads it at once (Uploader), the receiver joining each frames file's segments; the segment's file is deleted once the receiver acknowledges it, so a recording's frames leave the phone while it records. recording.json records every JSON file's and segment's size and hash, so the uploader sends the rest one by one with their hashes; <uuid> is the key they upload under, fixed before the recording has its id.
//
// scan_metadata.json's camera says where the frames come from: "front" is the TrueDepth camera through AVFoundation, color and depth from separate outputs at one frame rate; "rear" is the LiDAR camera through ARKit world tracking, the color image, its pose, the depth and its confidence from one ARFrame and so always at one timestamp. Depth is never filtered.
// The two streams are recorded independently, each frame with its own capture timestamp (seconds, host clock); a color frame and a depth frame were captured together when their timestamps are equal. Frame n of a .bin file is entry n of every frames list that describes it.
// All pixels, the intrinsics and the poses' camera frame are in the sensor's native orientation, unrotated and unmirrored; each color frame records how the phone was held.
//
// The recording's files (format_version "5.1", the version of the app that wrote it, <major>.<minor>, the minor counting the task's solved problems, with a patch level within 5.0), as the receiver stores them under <id>/:
//   scan_metadata.json             the scan as a whole: format_version, scan_id, name, start time, duration, phone model, id and iOS version, camera, frame rate, and whether it was recovered after the app stopped
//   color_frames.bin               every delivered color frame, encoded as FrameCodec.color ("row_delta_deflate"), concatenated with no header: frame n is the compressed_size bytes after frames 0 to n-1; decoded, each is exactly the frame the camera delivered, "420f", 8-bit full-range YCbCr 4:2:0, stored as its luma plane, h rows of w bytes (a Y byte per pixel), then its CbCr plane, h/2 rows of w bytes (a Cb, Cr byte pair per 2x2 pixels), rows tightly packed; its RGB is through ycbcr_matrix
//   color_frames_metadata.json     color_frames.bin's size, encoding, format and frame count; each delivered frame's timestamp, upright rotation (the clockwise rotation that turns it upright), CoreMotion gravity in the phone's device frame with its sample's timestamp, exposure time, compressed size and the SHA-256 of its decoded bytes; the dropped frames, each with its timestamp and why it was dropped (e.g. late, out_of_buffers, writer_busy)
//   depth_frames.bin               depth maps, each encoded as FrameCodec.map ("deflate"), concatenated with no header; decoded, each is exactly the map as delivered, rows tightly packed, little-endian, pixel_format "fdep" (Float32 metres) or "hdep" (Float16 metres); NaN or 0 marks a pixel without a reading
//   depth_frames_metadata.json     depth_frames.bin's size, encoding, format and frame count, and the rear's depth_frames_confidence.bin's; each delivered map's timestamp, compressed size and the SHA-256 of its decoded bytes, for the rear also its confidence map's, and, for the front, AVDepthData's filtered, accuracy and quality; the dropped maps (e.g. no_scene_depth)
//   depth_frames_confidence.bin    rear only: one map per depth map, in depth_frames.bin's order, encoded as depth_frames.bin is; decoded, depth_frames.bin's layout with a UInt8 per pixel, ARConfidenceLevel 0 low, 1 medium, 2 high
//   color_intrinsics.json          each color frame's fx, fy, cx, cy in color pixels (null when it came without them) and where they measure the principal point from; for the front, Apple's lens distortions, each with the runs of color frames it applies to, a color frame taking that of the depth map with its timestamp, else of the latest earlier one, else of the first, among the maps whose calibration has the lookup tables; a frame whose distortion is unknown is in no run
//   depth_intrinsics.json          the same for the depth maps, in depth pixels, each front map's distortion its own calibration's, unknown when that has no lookup tables
//   extrinsics.json                the transforms from the depth camera to the color camera, each with the runs of depth maps it applies to, identity for the rear, and, for the rear, each color frame's ARKit tracking state and pose
//
// A frame's line, with its compressed size and SHA-256, is written after its encoded bytes, and a segment is closed only after its frames' lines, so the segments hold at least the frames that have a line and a closed segment none without one; a color frame whose copy would push the raw bytes waiting to be encoded, written and hashed above maxQueuedBytes is dropped as writer_busy.
// The work directory holds everything finishing needs, so a directory left by a closed app or a failed finish is finished at the next launch, the segments it left open closed, the last cut to the frames that have a line:
//   start.json                                                    what is known when recording starts: camera, start time, phone, stream format, where it goes
//   color_frames.jsonl, depth_frames.jsonl                        one line per delivered frame, in the frames files' order: its entries in the JSON files
//   color_dropped.jsonl, depth_dropped.jsonl                      one line per dropped frame, in arrival order
//   segments.jsonl                                                one line per closed segment, in each frames file's order: its frames file, name, size and SHA-256
//   the JSON files                                                written when finishing begins, from start.json and the lines
//   recording.json                                                the recording's RecordingInfo with every JSON file's and segment's size and SHA-256, written once the JSON files are; a finish that finds it only removes start.json and the lines and renames the directory
// and Documents/segments/<uuid>/ holds each frames file's segments, <frames file>.<index, 6 digits>, written as the frames arrive, each deleted once the receiver acknowledges it.
// A recording recovered at the next launch hashes the segments a closed app left open by reading them; so are the files of a recording apps 4.1 to 4.5 finished, whose recording.json lists no members, when this app first finds it: the only times a recording's files are read back.
final class Recording {
    static var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    private static var workRoot: URL { documents.appendingPathComponent("work", isDirectory: true) }
    // The raw bytes of the frames waiting to be encoded, written and hashed stay within this: about 29 front or 129 rear color frames.
    private static let maxQueuedBytes = 512 << 20

    private static let colorFramesName = "color_frames.bin"
    private static let depthFramesName = "depth_frames.bin"
    private static let confidenceName = "depth_frames_confidence.bin"
    // A frames file is written in segments of at least this many bytes, each uploaded as soon as it is closed: about 10 front or 40 rear color frames.
    private static let segmentBytes = 64 << 20
    private static var segmentsRoot: URL { documents.appendingPathComponent("segments", isDirectory: true) }
    // The work directory's own files, removed once the recording is finished.
    private static let startName = "start.json"
    private static let colorLinesName = "color_frames.jsonl"
    private static let colorDroppedName = "color_dropped.jsonl"
    private static let depthLinesName = "depth_frames.jsonl"
    private static let depthDroppedName = "depth_dropped.jsonl"
    private static let segmentLinesName = "segments.jsonl"

    // Where the frames files' segments of the recording uploading under uploadId are kept until the receiver acknowledges them.
    static func segmentsDirectory(_ uploadId: String) -> URL { segmentsRoot.appendingPathComponent(uploadId, isDirectory: true) }

    // Whether a recording's member is a segment of a frames file, <frames file>.<index, 6 digits>.
    static func isSegment(_ name: String) -> Bool {
        guard let index = name.split(separator: ".").last else { return false }
        return index.count == 6 && index.allSatisfy { $0.isASCII && $0.isNumber }
    }

    // A segment's name: its frames file's and its index.
    private static func segmentName(_ file: String, _ index: Int) -> String { "\(file).\(String(format: "%06d", index))" }

    // start.json and each .jsonl line on one line, the recording's JSON files pretty-printed; JSONEncoder writes each number in the shortest form that reads back exactly.
    private static let lineEncoder = encoder([.sortedKeys])
    private static let fileEncoder = encoder([.prettyPrinted, .sortedKeys])
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static func encoder(_ formatting: JSONEncoder.OutputFormatting) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = formatting
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private let directory: URL
    // The key the recording's files upload under, its work directory's name, fixed before the recording has its id.
    let uploadId: String
    private let segmentsDirectory: URL
    // Called on hashQueue with each closed segment, to upload it.
    private let onSegment: (Segment) -> Void
    private let camera: DepthCamera
    private let format: StreamFormat
    private let colorFile: FramesFile
    private let depthFile: FramesFile
    // The rear's depth_frames_confidence.bin.
    private let confidenceFile: FramesFile?
    private let colorLines: FileHandle
    private let colorDropped: FileHandle
    private let depthLines: FileHandle
    private let depthDropped: FileHandle
    // Each write's autoreleased memory is released as soon as it is written.
    private let fileQueue = DispatchQueue(label: "recording.files", autoreleaseFrequency: .workItem)
    // Encodes several frames at once: a front recording delivers about 0.29 GB of frames a second, more than one core encodes.
    private let encodeQueue = DispatchQueue(label: "recording.encode", qos: .userInitiated, attributes: .concurrent, autoreleaseFrequency: .workItem)
    // Hashes each frame's encoded bytes, in file order, once fileQueue has written them.
    private let hashQueue = DispatchQueue(label: "recording.hashes", autoreleaseFrequency: .workItem)
    // Under bufferLock: the raw bytes of the frames queued and not yet encoded, written and hashed, and the color buffers free for the next frame, each colorBytesPerFrame long; a color buffer goes back on the free list once its frame is encoded, so the bound on queuedBytes bounds how many exist, and all are freed when the files are closed.
    private let bufferLock = NSLock()
    private var queuedBytes = 0
    private var freeColorBuffers: [UnsafeMutableRawPointer] = []
    // Entered for each sample's frames when they are queued, left once they are encoded, written with their line and hashed; finishing waits for it to empty.
    private let framesInFlight = DispatchGroup()

    // Owned by fileQueue: the first failed write, after which nothing more is written.
    private var fileError: Error?
    // Owned by hashQueue: segments.jsonl, and the first failed write to it, after which no segment is handed over to be uploaded and deleted.
    private let segmentLines: FileHandle
    private var segmentLinesError: Error?

    init(camera: DepthCamera, format: StreamFormat, target: RecordingTarget, onSegment: @escaping (Segment) -> Void) throws {
        precondition((format.confidencePixelFormat != nil) == (camera == .rear), "a \(camera.rawValue) recording of a stream \(format.confidencePixelFormat == nil ? "without" : "with") confidence")
        if let confidencePixelFormat = format.confidencePixelFormat {
            // depth_frames_confidence.bin holds one byte per depth pixel.
            precondition(confidencePixelFormat == kCVPixelFormatType_OneComponent8, "confidence pixel format \(fourCC(confidencePixelFormat)) is not one byte per pixel")
        }
        self.camera = camera
        self.format = format
        directory = Self.workRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        uploadId = directory.lastPathComponent
        segmentsDirectory = Self.segmentsDirectory(uploadId)
        self.onSegment = onSegment
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: segmentsDirectory, withIntermediateDirectories: true)

        var systemInfo = utsname()
        uname(&systemInfo)
        let start = Start(camera: camera, startTimeUtc: Date(),
                          phoneModel: withUnsafeBytes(of: &systemInfo.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) },
                          phoneId: UIDevice.current.identifierForVendor?.uuidString, iosVersion: UIDevice.current.systemVersion, format: format, target: target)
        try Self.lineEncoder.encode(start).write(to: directory.appendingPathComponent(Self.startName))

        colorFile = FramesFile(segmentsDirectory, Self.colorFramesName)
        colorLines = try Self.create(directory.appendingPathComponent(Self.colorLinesName))
        colorDropped = try Self.create(directory.appendingPathComponent(Self.colorDroppedName))
        depthFile = FramesFile(segmentsDirectory, Self.depthFramesName)
        depthLines = try Self.create(directory.appendingPathComponent(Self.depthLinesName))
        depthDropped = try Self.create(directory.appendingPathComponent(Self.depthDroppedName))
        confidenceFile = camera == .rear ? FramesFile(segmentsDirectory, Self.confidenceName) : nil
        segmentLines = try Self.create(directory.appendingPathComponent(Self.segmentLinesName))
    }

    private static func create(_ url: URL) throws -> FileHandle {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw RecorderError("cannot create \(url.lastPathComponent)") }
        return try FileHandle(forWritingTo: url)
    }

    // A frames file of encoded frames, written on fileQueue as segments in the segments directory, past the page cache, with the open segment's size and SHA-256, added on hashQueue after the writes.
    private final class FramesFile {
        let name: String
        private let directory: URL
        // Owned by fileQueue: the open segment's handle, once a frame is written to it, its index and the bytes written to it.
        private var handle: FileHandle?
        private var index = 0
        private(set) var written = 0
        // Owned by hashQueue.
        var size = 0
        var hasher = SHA256()

        init(_ directory: URL, _ name: String) {
            self.directory = directory
            self.name = name
        }

        // Writes the bytes to the open segment, opening it if none is open.
        func write(_ bytes: Data) throws {
            if handle == nil {
                let segment = Recording.segmentName(name, index)
                let handle = try Recording.create(directory.appendingPathComponent(segment))
                // The frames are never read back while recording; caching them would only add a copy and memory pressure.
                guard fcntl(handle.fileDescriptor, F_NOCACHE, 1) != -1 else { throw RecorderError("cannot turn off caching of \(segment): \(String(cString: strerror(errno)))") }
                self.handle = handle
            }
            try handle!.write(contentsOf: bytes)
            written += bytes.count
        }

        // Closes the open segment and returns its name; the next write opens the next segment.
        func closeSegment() throws -> String {
            let segment = Recording.segmentName(name, index)
            try handle?.close()
            handle = nil
            index += 1
            written = 0
            return segment
        }
    }

    // A frame's raw bytes on their way to a frames file, and what releases them once they are encoded.
    private struct RawFrame {
        let bytes: UnsafeMutableRawBufferPointer
        let codec: FrameCodec
        let file: FramesFile
        let release: () -> Void
    }

    // A sample's encoded frames, each set by its encoding work item and read once all are done.
    private final class EncodedFrames {
        private let lock = NSLock()
        private var frames: [FrameCodec.Encoded?]

        init(count: Int) { frames = Array(repeating: nil, count: count) }

        func set(_ index: Int, _ frame: FrameCodec.Encoded) { lock.withLock { frames[index] = frame } }

        var all: [FrameCodec.Encoded] { lock.withLock { frames.map { $0! } } }
    }

    // The frame calls below run on the capture data queue.

    // Returns whether the frame is queued; a frame whose copy would push the raw bytes waiting to be encoded, written and hashed above maxQueuedBytes is recorded as dropped. Only the rear's frames come with a pose.
    func appendColor(_ color: ColorSample, orientation: Orientation) -> Bool {
        precondition((color.pose != nil) == (camera == .rear), "a \(camera.rawValue) color frame \(color.pose == nil ? "without" : "with") a pose")
        // Only this queue adds to queuedBytes, so the bound still holds once the frame is queued.
        guard bufferLock.withLock({ queuedBytes }) + format.colorBytesPerFrame <= Self.maxQueuedBytes else {
            recordDroppedColor(at: color.time, reason: "writer_busy")
            return false
        }
        // The line keeps values only, so the camera's buffer goes back as soon as it is copied.
        let timestamp = CMTimeGetSeconds(color.time)
        let gravity = Nullable(orientation.gravity.map { g in [g.x, g.y, g.z].map { ($0 * 100_000).rounded() / 100_000 } })
        let exposureDuration = color.exposureDuration
        let intrinsics = color.intrinsics.map(Intrinsics.init)
        let pose = color.pose.map(CameraPose.init)
        store([copyColor(color.image)], to: colorLines) { encoded in
            ColorLine(frame: ColorFramesMetadata.Frame(timestamp: timestamp, uprightRotationDeg: orientation.uprightRotationDegrees, gravity: gravity,
                                                       gravityTimestamp: Nullable(orientation.gravityTime), exposureDurationS: exposureDuration,
                                                       compressedSize: encoded[0].bytes.count, rawSha256: encoded[0].rawSHA256),
                      intrinsics: intrinsics, pose: pose)
        }
        return true
    }

    func recordDroppedColor(at time: CMTime, reason: String) {
        append(DroppedFrame(timestamp: CMTimeGetSeconds(time), reason: reason), to: colorDropped)
    }

    // Only the front's maps come with AVDepthData's flags, and a calibration when Apple gives one.
    func appendDepth(_ depth: DepthSample) {
        precondition((depth.flags != nil) == (camera == .front), "a \(camera.rawValue) depth map \(depth.flags == nil ? "without" : "with") AVDepthData's flags")
        precondition(depth.calibration == nil || camera == .front, "calibration from the rear camera, which has none")
        var frames = [copyMap(depth.map, width: format.depthWidth, height: format.depthHeight, pixelFormat: format.depthPixelFormat, bytesPerPixel: format.depthBytesPerPixel, to: depthFile)]
        if let confidenceFile, let confidencePixelFormat = format.confidencePixelFormat {
            guard let confidence = depth.confidence else { preconditionFailure("depth map at \(CMTimeGetSeconds(depth.time)) s came without its confidence map") }
            frames.append(copyMap(confidence, width: format.depthWidth, height: format.depthHeight, pixelFormat: confidencePixelFormat, bytesPerPixel: 1, to: confidenceFile))
        } else {
            precondition(depth.confidence == nil, "confidence map from a source whose format has none")
        }
        let timestamp = CMTimeGetSeconds(depth.time)
        let flags = depth.flags
        let calibration = depth.calibration
        let intrinsics = depth.intrinsics.map(Intrinsics.init)
        let distortion = calibration.flatMap { Distortion($0, width: format.depthWidth, height: format.depthHeight) }
        let colorDistortion = calibration.flatMap { Distortion($0, width: format.colorWidth, height: format.colorHeight) }
        // Row-major, while a simd matrix is indexed by column first.
        let depthToColor = calibration.map { c in (0..<3).map { row in (0..<4).map { column in c.extrinsicMatrix[column][row] } } }
        store(frames, to: depthLines) { encoded in
            // The rear's confidence map follows its depth map.
            let confidence = encoded.count > 1 ? encoded[1] : nil
            return DepthLine(
                frame: DepthFramesMetadata.Frame(timestamp: timestamp, filtered: flags?.filtered,
                                                 accuracy: flags.map { $0.accuracy == .absolute ? "absolute" : "relative" }, quality: flags.map { $0.quality == .high ? "high" : "low" },
                                                 compressedSize: encoded[0].bytes.count, rawSha256: encoded[0].rawSHA256,
                                                 confidenceCompressedSize: confidence?.bytes.count, confidenceRawSha256: confidence?.rawSHA256),
                intrinsics: intrinsics, distortion: distortion, colorDistortion: colorDistortion, depthToColor: depthToColor)
        }
    }

    func recordDroppedDepth(at time: CMTime, reason: String) {
        append(DroppedFrame(timestamp: CMTimeGetSeconds(time), reason: reason), to: depthDropped)
    }

    // Copies a 420f frame's planes without their row padding, the luma rows, then the CbCr rows, into a free color buffer, which goes back on the free list once the frame is encoded.
    private func copyColor(_ image: CVPixelBuffer) -> RawFrame {
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
        return RawFrame(bytes: UnsafeMutableRawBufferPointer(start: buffer, count: format.colorBytesPerFrame), codec: .color(width: width, height: height), file: colorFile) { [self] in
            bufferLock.withLock { freeColorBuffers.append(buffer) }
        }
    }

    // A color buffer aligned to iOS's 16 KiB pages.
    private func newColorBuffer() -> UnsafeMutableRawPointer {
        var buffer: UnsafeMutableRawPointer?
        let status = posix_memalign(&buffer, 16384, format.colorBytesPerFrame)
        precondition(status == 0, "cannot allocate a \(format.colorBytesPerFrame)-byte color buffer: \(String(cString: strerror(status)))")
        return buffer!
    }

    // Copies the map's rows without their padding into memory of its own, freed once the map is encoded.
    private func copyMap(_ map: CVPixelBuffer, width: Int, height: Int, pixelFormat: OSType, bytesPerPixel: Int, to file: FramesFile) -> RawFrame {
        precondition(CVPixelBufferGetWidth(map) == width && CVPixelBufferGetHeight(map) == height && CVPixelBufferGetPixelFormatType(map) == pixelFormat,
                     "\(CVPixelBufferGetWidth(map))×\(CVPixelBufferGetHeight(map)) \(fourCC(CVPixelBufferGetPixelFormatType(map))) map differs from the stream format's \(width)×\(height) \(fourCC(pixelFormat))")
        let rowBytes = width * bytesPerPixel
        let bytes = UnsafeMutableRawBufferPointer.allocate(byteCount: rowBytes * height, alignment: 16)
        CVPixelBufferLockBaseAddress(map, .readOnly)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(map)
        let base = CVPixelBufferGetBaseAddress(map)!
        for y in 0..<height {
            memcpy(bytes.baseAddress!.advanced(by: y * rowBytes), base.advanced(by: y * bytesPerRow), rowBytes)
        }
        CVPixelBufferUnlockBaseAddress(map, .readOnly)
        return RawFrame(bytes: bytes, codec: .map, file: file) { bytes.deallocate() }
    }

    // Writes a line to a .jsonl file on the file queue, where it is encoded, off the capture queue.
    private func append(_ line: some Encodable, to handle: FileHandle) {
        perform { try handle.write(contentsOf: Self.lineEncoder.encode(line) + Data("\n".utf8)) }
    }

    // Encodes the sample's frames on encodeQueue, beside other samples' frames; then, on fileQueue in the order samples were stored, writes each frame to its file and the line made from them, and adds the written bytes to each file's hash on hashQueue. The frames count in queuedBytes and framesInFlight until hashed.
    private func store<Line: Encodable>(_ frames: [RawFrame], to lines: FileHandle, line: @escaping ([FrameCodec.Encoded]) -> Line) {
        let rawBytes = frames.reduce(0) { $0 + $1.bytes.count }
        bufferLock.withLock { queuedBytes += rawBytes }
        framesInFlight.enter()
        let encoded = EncodedFrames(count: frames.count)
        let encoding = DispatchGroup()
        for (index, frame) in frames.enumerated() {
            encodeQueue.async(group: encoding) {
                encoded.set(index, frame.codec.encode(frame.bytes))
                frame.release()
            }
        }
        fileQueue.async { [self] in
            // fileQueue runs one sample at a time, so the frames reach their files in the order they were stored.
            encoding.wait()
            let results = encoded.all
            var written = false
            // A sample has at most one frame per frames file.
            var closed: [(file: FramesFile, segment: String)] = []
            if fileError == nil {
                do {
                    for (frame, result) in zip(frames, results) { try frame.file.write(result.bytes) }
                    written = true
                    try lines.write(contentsOf: Self.lineEncoder.encode(line(results)) + Data("\n".utf8))
                    // After the frames' line, so a closed segment holds no frame without one.
                    for frame in frames where frame.file.written >= Self.segmentBytes { closed.append((frame.file, try frame.file.closeSegment())) }
                } catch {
                    fileError = error
                }
            }
            hashQueue.async { [self] in
                if written {
                    for (frame, result) in zip(frames, results) {
                        frame.file.hasher.update(data: result.bytes)
                        frame.file.size += result.bytes.count
                    }
                }
                for (file, segment) in closed { handOver(segment, of: file) }
                bufferLock.withLock { queuedBytes -= rawBytes }
                framesInFlight.leave()
            }
        }
    }

    // Records a closed segment, its bytes hashed, in segments.jsonl and hands it over to be uploaded, starting the frames file's next segment's size and hash; on hashQueue. A segment that could not be recorded stays on the phone, for a recovery to find.
    private func handOver(_ segment: String, of file: FramesFile) {
        let closed = Segment(uploadId: uploadId, name: segment, file: segmentsDirectory.appendingPathComponent(segment), size: file.size, sha256: file.hasher.finalize().hex)
        (file.size, file.hasher) = (0, SHA256())
        guard segmentLinesError == nil else { return }
        do {
            try segmentLines.write(contentsOf: Self.lineEncoder.encode(SegmentLine(file: file.name, name: segment, size: closed.size, sha256: closed.sha256)) + Data("\n".utf8))
        } catch {
            segmentLinesError = error
            return
        }
        onSegment(closed)
    }

    // Runs a file write on the file queue, in the order the writes were asked for.
    private func perform(_ write: @escaping () throws -> Void) {
        fileQueue.async { [self] in
            guard fileError == nil else { return }
            do { try write() } catch { fileError = error }
        }
    }

    // Once every frame is encoded, written and hashed, closes and hands over the open segments, frees the color buffers, closes the files and finishes the recording; userName is nil when the user left it unnamed.
    func finish(userName: String?, completion: @escaping (Result<RecordingInfo?, Error>) -> Void) {
        // The lines' writes, queued while recording, are ahead of this on fileQueue, so they are in too.
        framesInFlight.notify(queue: fileQueue) { [self] in
            completion(Result {
                bufferLock.withLock {
                    freeColorBuffers.forEach { free($0) }
                    freeColorBuffers.removeAll()
                }
                for handle in [colorLines, colorDropped, depthLines, depthDropped] { try handle.close() }
                if let fileError { throw fileError }
                let closed = try [colorFile, depthFile, confidenceFile].compactMap { $0 }.filter { $0.written > 0 }.map { (file: $0, segment: try $0.closeSegment()) }
                try hashQueue.sync {
                    for (file, segment) in closed { handOver(segment, of: file) }
                    try segmentLines.close()
                    if let segmentLinesError { throw segmentLinesError }
                }
                return try Self.finish(directory, userName: userName, recovered: false)
            })
        }
    }

    // Work directories of recordings that were never finished.
    static func leftovers() -> [URL] {
        // Documents/work does not exist before the first recording.
        (try? FileManager.default.contentsOfDirectory(at: workRoot, includingPropertiesForKeys: nil)) ?? []
    }

    // Finishes, under its date and time, a work directory a closed app or a failed finish left; the segments it left open are hashed by reading them.
    static func recover(_ directory: URL) throws -> RecordingInfo? {
        try finish(directory, userName: nil, recovered: true)
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

    // Gives a recording apps 4.1 to 4.5 finished its members, each hashed by reading it and acknowledged when the recording was uploaded, rewriting its recording.json; it is otherwise as those apps wrote it.
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
        // The files apps 4.1 to 4.5 wrote, in the order their archive held them.
        let names = ["color.bin", "depth.bin", "color.csv", "depth.csv", "metadata.json"] + (listed.camera == .rear ? ["confidence.bin"] : ["calibration.jsonl"])
        let members = try names.map { name -> RecordingInfo.Member in
            let read = try hash(directory.appendingPathComponent(name))
            return RecordingInfo.Member(name: name, size: read.size, sha256: read.sha256, uploaded: listed.uploaded)
        }
        let info = RecordingInfo(id: listed.id, name: listed.name, namedByUser: listed.namedByUser, startTime: listed.startTime, durationSeconds: listed.durationSeconds, camera: listed.camera, uploadId: nil, target: nil, members: members, uploaded: listed.uploaded)
        try info.write(to: infoFile)
        return info
    }

    // Finishes a work directory where it lies, copying none of its frames: closes the segments a closed app left open, writes the JSON files and recording.json with every JSON file's and segment's size and SHA-256, removes start.json, the lines and segments.jsonl and renames the directory to Documents/<id>/, resuming a finish that was cut short; recovered is whether the app was closed while recording. Returns nil, removing the directory and its segments, when a stream has no frames; a failed finish leaves the directory to be finished at the next launch, and its error names the directory.
    private static func finish(_ directory: URL, userName: String?, recovered: Bool) throws -> RecordingInfo? {
        do {
            return try finishWorkDirectory(directory, userName: userName, recovered: recovered)
        } catch {
            throw RecorderError("work/\(directory.lastPathComponent): \(error.localizedDescription)")
        }
    }

    private static func finishWorkDirectory(_ directory: URL, userName: String?, recovered: Bool) throws -> RecordingInfo? {
        let infoFile = directory.appendingPathComponent(RecordingInfo.fileName)
        if !FileManager.default.fileExists(atPath: infoFile.path) {
            guard let info = try writeFiles(directory, userName: userName, recovered: recovered) else {
                try FileManager.default.removeItem(at: directory)
                let segments = segmentsDirectory(directory.lastPathComponent)
                if FileManager.default.fileExists(atPath: segments.path) { try FileManager.default.removeItem(at: segments) }
                return nil
            }
            try info.write(to: infoFile)
        }
        let info = try RecordingInfo.load(infoFile)
        for name in [startName, colorLinesName, colorDroppedName, depthLinesName, depthDroppedName, segmentLinesName] {
            let url = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
        try FileManager.default.moveItem(at: directory, to: info.directory)
        return info
    }

    // Writes the recording's JSON files from start.json, the lines and segments.jsonl, closing the segments a closed app left open, and returns the recording's RecordingInfo with every JSON file's and segment's size and SHA-256; nil when a stream has no frames.
    private static func writeFiles(_ directory: URL, userName: String?, recovered: Bool) throws -> RecordingInfo? {
        let file = { (name: String) in directory.appendingPathComponent(name) }
        let start = try decoder.decode(Start.self, from: Data(contentsOf: file(startName)))
        let format = start.format
        let color: [ColorLine] = try lines(file(colorLinesName))
        let colorDropped: [DroppedFrame] = try lines(file(colorDroppedName))
        let depth: [DepthLine] = try lines(file(depthLinesName))
        let depthDropped: [DroppedFrame] = try lines(file(depthDroppedName))
        guard !color.isEmpty, !depth.isEmpty else { return nil }
        // colorDistortions walks both streams in time order.
        for (name, times) in [(colorLinesName, color.map(\.frame.timestamp)), (depthLinesName, depth.map(\.frame.timestamp))] {
            guard zip(times, times.dropFirst()).allSatisfy({ $0 < $1 }) else { throw RecorderError("\(name) is not in time order") }
        }
        let poses = color.compactMap(\.pose)
        guard poses.count == (start.camera == .rear ? color.count : 0) else { throw RecorderError("\(colorLinesName) has \(poses.count) poses for \(color.count) \(start.camera.rawValue) frames") }

        let uploadId = directory.lastPathComponent
        let segmentsDirectory = segmentsDirectory(uploadId)
        let closedSegments: [SegmentLine] = try lines(file(segmentLinesName))
        // A frames file's segments, holding exactly its frames with a line: those segments.jsonl records, then those a closed app left open, each recorded once hashed by reading it, the last cut to the frames with a line and any after it, holding no frame with one, removed.
        func segments(_ name: String, holding bytes: Int) throws -> [SegmentLine] {
            var segments = closedSegments.filter { $0.file == name }
            guard segments.map(\.name) == segments.indices.map({ segmentName(name, $0) }) else { throw RecorderError("\(segmentLinesName) lists \(name)'s segments out of order") }
            var held = segments.reduce(0) { $0 + $1.size }
            guard held <= bytes else { throw RecorderError("\(name)'s closed segments hold \(held) bytes, more than its lines' \(bytes)") }
            let segmentLinesFile = try FileHandle(forWritingTo: file(segmentLinesName))
            defer { try? segmentLinesFile.close() }
            try segmentLinesFile.seekToEnd()
            while held < bytes {
                let url = segmentsDirectory.appendingPathComponent(segmentName(name, segments.count))
                guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { throw RecorderError("\(name) lacks segment \(segments.count), which its lines' frames need") }
                // A frame's encoded bytes are written before its line, so a recording cut off by a closed app can hold frames without one.
                if held + size > bytes { try truncate(url, toBytes: bytes - held) }
                let read = try hash(url)
                let segment = SegmentLine(file: name, name: url.lastPathComponent, size: read.size, sha256: read.sha256)
                try segmentLinesFile.write(contentsOf: lineEncoder.encode(segment) + Data("\n".utf8))
                segments.append(segment)
                held += read.size
            }
            var after = segments.count
            while true {
                let url = segmentsDirectory.appendingPathComponent(segmentName(name, after))
                guard FileManager.default.fileExists(atPath: url.path) else { break }
                try FileManager.default.removeItem(at: url)
                after += 1
            }
            return segments
        }
        // Each segment as a member, acknowledged by the receiver when its file is gone.
        func members(_ segments: [SegmentLine]) -> [RecordingInfo.Member] {
            segments.map { RecordingInfo.Member(name: $0.name, size: $0.size, sha256: $0.sha256, uploaded: !FileManager.default.fileExists(atPath: segmentsDirectory.appendingPathComponent($0.name).path)) }
        }
        let colorSegments = try segments(colorFramesName, holding: color.reduce(0) { $0 + $1.frame.compressedSize })
        let depthSegments = try segments(depthFramesName, holding: depth.reduce(0) { $0 + $1.frame.compressedSize })
        let confidenceSegments = try format.confidencePixelFormat.map { _ in
            try segments(confidenceName, holding: try depth.reduce(0) { total, line in
                guard let size = line.frame.confidenceCompressedSize else { throw RecorderError("\(depthLinesName) has a rear map without its confidence map's size") }
                return total + size
            })
        }
        // Writes a JSON file and returns it with the size and SHA-256 of the bytes written.
        func json(_ name: String, _ value: some Encodable) throws -> RecordingInfo.Member {
            let data = try fileEncoder.encode(value)
            try data.write(to: file(name))
            return RecordingInfo.Member(name: name, size: data.count, sha256: SHA256.hash(data: data).hex, uploaded: false)
        }

        let id = id(start.startTimeUtc, start.camera, userName)
        // An unnamed recording is named by its start date and time and its camera.
        let name = userName ?? "\(formatted(start.startTimeUtc, "yyyy-MM-dd HH:mm:ss")) \(start.camera == .front ? "Front" : "Rear")"
        let times = color.map(\.frame.timestamp) + colorDropped.map(\.timestamp) + depth.map(\.frame.timestamp) + depthDropped.map(\.timestamp)
        let duration = times.max()! - times.min()!
        let front = start.camera == .front
        let joinedSize = { (segments: [SegmentLine]) in segments.reduce(0) { $0 + $1.size } }
        // ARKit registers scene depth to the captured image.
        let depthToColor: [[[Float]]?] = front ? depth.map(\.depthToColor) : Array(repeating: [[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0]], count: depth.count)
        // The front's color distortions, whose scales also carry Apple's color intrinsic matrices about the frame's corner.
        let colorDistortion = front ? colorDistortions(color, depth) : nil
        let colorIntrinsics = colorDistortion.map { zip(color, $0).map { line, distortion in
            guard let intrinsics = line.intrinsics, let scale = distortion?.scale else { return line.intrinsics }
            return intrinsics.carriedAboutCorner(scale: scale)
        } } ?? color.map(\.intrinsics)
        let members = try [
            json("scan_metadata.json", ScanMetadata(
                formatVersion: "5.1", scanId: id, name: name, startTimeUtc: start.startTimeUtc, durationS: duration, phoneModel: start.phoneModel,
                phoneId: Nullable(start.phoneId), iosVersion: start.iosVersion, camera: start.camera, frameRate: format.frameRate, recovered: recovered)),
        ] + members(colorSegments) + [
            json("color_frames_metadata.json", ColorFramesMetadata(
                file: colorFramesName, size: joinedSize(colorSegments), encoding: FrameCodec.color(width: format.colorWidth, height: format.colorHeight).name, width: format.colorWidth, height: format.colorHeight,
                pixelFormat: fourCC(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange), ycbcrMatrix: format.colorYCbCrMatrix, frameCount: color.count,
                frames: color.map(\.frame), dropped: colorDropped.sorted { $0.timestamp < $1.timestamp })),
        ] + members(depthSegments) + [
            json("depth_frames_metadata.json", DepthFramesMetadata(
                file: depthFramesName, size: joinedSize(depthSegments), encoding: FrameCodec.map.name, width: format.depthWidth, height: format.depthHeight,
                pixelFormat: fourCC(format.depthPixelFormat), frameCount: depth.count,
                confidence: confidenceSegments.flatMap { segments in format.confidencePixelFormat.map { DepthFramesMetadata.Confidence(file: confidenceName, size: joinedSize(segments), encoding: FrameCodec.map.name, pixelFormat: fourCC($0)) } },
                frames: depth.map(\.frame), dropped: depthDropped.sorted { $0.timestamp < $1.timestamp })),
        ] + members(confidenceSegments ?? []) + [
            json("color_intrinsics.json", IntrinsicsFile(
                imageWidth: format.colorWidth, imageHeight: format.colorHeight, principalPointOrigin: format.principalPointOrigin,
                frames: colorIntrinsics, distortions: colorDistortion.map(distortions))),
            json("depth_intrinsics.json", IntrinsicsFile(
                imageWidth: format.depthWidth, imageHeight: format.depthHeight, principalPointOrigin: format.principalPointOrigin,
                frames: depth.map(\.intrinsics), distortions: front ? distortions(depth.map(\.distortion)) : nil)),
            json("extrinsics.json", ExtrinsicsFile(
                depthToColor: ranges(depthToColor).map { DepthToColor(matrix: $0.value, depthFrameRanges: $0.ranges) },
                cameraPoses: front ? nil : poses)),
        ]
        return RecordingInfo(id: id, name: name, namedByUser: userName != nil, startTime: start.startTimeUtc, durationSeconds: duration, camera: start.camera, uploadId: uploadId, target: start.target, members: members, uploaded: false)
    }

    // A .jsonl file's lines, each decoded as a Line.
    private static func lines<Line: Decodable>(_ url: URL) throws -> [Line] {
        try Data(contentsOf: url).split(separator: UInt8(ascii: "\n")).enumerated().map { number, line in
            do {
                return try decoder.decode(Line.self, from: line)
            } catch {
                throw RecorderError("\(url.lastPathComponent) line \(number + 1): \(error)")
            }
        }
    }

    // Each color frame's lens distortion: that of the depth map with the same timestamp, else of the latest earlier one, else of the first, among the maps whose calibration has the lookup tables; nil for every frame when none did. Both streams are in time order.
    private static func colorDistortions(_ color: [ColorLine], _ depth: [DepthLine]) -> [Distortion?] {
        let known = depth.filter { $0.colorDistortion != nil }
        // The first of those maps later than the color frame.
        var next = 0
        return color.map { line in
            while next < known.count && known[next].frame.timestamp <= line.frame.timestamp { next += 1 }
            return known.isEmpty ? nil : known[max(next - 1, 0)].colorDistortion
        }
    }

    // An intrinsics file's distortions: each distinct distortion once, with the runs of frames it applies to.
    private static func distortions(_ perFrame: [Distortion?]) -> [DistortionRanges] {
        ranges(perFrame).map { DistortionRanges(center: $0.value.center, lookupTable: $0.value.lookupTable, inverseLookupTable: $0.value.inverseLookupTable, frameRanges: $0.ranges) }
    }

    // Each distinct value once, in order of first appearance, with the inclusive runs [first, last] of the positions holding it; a nil is in no run.
    private static func ranges<Value: Hashable>(_ values: [Value?]) -> [(value: Value, ranges: [[Int]])] {
        var grouped: [(value: Value, ranges: [[Int]])] = []
        var groupOf: [Value: Int] = [:]
        for (position, value) in values.enumerated() {
            guard let value else { continue }
            guard let group = groupOf[value] else {
                groupOf[value] = grouped.count
                grouped.append((value, [[position, position]]))
                continue
            }
            let last = grouped[group].ranges.count - 1
            if grouped[group].ranges[last][1] == position - 1 {
                grouped[group].ranges[last][1] = position
            } else {
                grouped[group].ranges.append([position, position])
            }
        }
        return grouped
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

    // Cuts a file of encoded frames to its first count bytes, the frames with a line.
    private static func truncate(_ url: URL, toBytes count: Int) throws {
        let handle = try FileHandle(forWritingTo: url)
        guard try handle.seekToEnd() >= UInt64(count) else { throw RecorderError("\(url.lastPathComponent) holds fewer bytes than its lines' frames") }
        try handle.truncate(atOffset: UInt64(count))
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
}

// A closed segment of a recording's frames file, to upload under the recording's key: its name, the file holding it, its size and SHA-256.
struct Segment {
    let uploadId: String
    let name: String
    let file: URL
    let size: Int
    let sha256: String
}

extension SHA256Digest {
    // As 64 lowercase hex characters, the way recording.json, the manifest and the receiver write a SHA-256.
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

// The work directory's files and the recording's JSON files as JSONEncoder writes them, every key in snake_case.

// start.json.
private struct Start: Codable {
    let camera: DepthCamera
    let startTimeUtc: Date
    // uname's machine, e.g. iPhone14,3.
    let phoneModel: String
    // identifierForVendor; nil when iOS gives none.
    let phoneId: String?
    let iosVersion: String
    let format: StreamFormat
    // Where the recording goes; nil in a work directory an app before 5.0.3 left.
    let target: RecordingTarget?
}

// A color_frames.jsonl line: a delivered color frame's entries in the JSON files.
private struct ColorLine: Codable {
    let frame: ColorFramesMetadata.Frame
    let intrinsics: Intrinsics?
    // The rear's.
    let pose: CameraPose?
}

// A depth_frames.jsonl line: a delivered depth map's entries in the JSON files, and the lens distortion of the color frames that take this map's.
private struct DepthLine: Codable {
    let frame: DepthFramesMetadata.Frame
    let intrinsics: Intrinsics?
    // The front's, from the map's calibration: its lens distortion for the depth map and for the color image, nil when the calibration has no lookup tables, and the transform from the depth camera to the color camera.
    let distortion: Distortion?
    let colorDistortion: Distortion?
    let depthToColor: [[Float]]?
}

// A value written as null when absent, where JSONEncoder would leave an absent optional's key out.
private struct Nullable<Value: Codable>: Codable {
    let value: Value?

    init(_ value: Value?) { self.value = value }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        value = container.decodeNil() ? nil : try container.decode(Value.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let value { try container.encode(value) } else { try container.encodeNil() }
    }
}

// scan_metadata.json.
private struct ScanMetadata: Encodable {
    let formatVersion: String
    let scanId: String
    let name: String
    let startTimeUtc: Date
    let durationS: Double
    let phoneModel: String
    let phoneId: Nullable<String>
    let iosVersion: String
    let camera: DepthCamera
    let frameRate: Double
    let recovered: Bool
}

// color_frames_metadata.json.
private struct ColorFramesMetadata: Encodable {
    let file: String
    // The joined segments'.
    let size: Int
    // FrameCodec's name.
    let encoding: String
    let width: Int
    let height: Int
    let pixelFormat: String
    let ycbcrMatrix: String
    let frameCount: Int
    let frames: [Frame]
    let dropped: [DroppedFrame]

    // A delivered color frame.
    struct Frame: Codable {
        let timestamp: Double
        let uprightRotationDeg: Int
        // CoreMotion gravity in g to 5 decimals, and its sample's timestamp; null before the first motion sample.
        let gravity: Nullable<[Double]>
        let gravityTimestamp: Nullable<Double>
        let exposureDurationS: Double
        // The frame as stored in the file, and the SHA-256 of its decoded bytes.
        let compressedSize: Int
        let rawSha256: String
    }
}

// A segments.jsonl line: a closed segment of a frames file.
private struct SegmentLine: Codable {
    let file: String
    let name: String
    let size: Int
    let sha256: String
}

// A dropped frame in color_frames_metadata.json or depth_frames_metadata.json.
private struct DroppedFrame: Codable {
    let timestamp: Double
    let reason: String
}

// depth_frames_metadata.json.
private struct DepthFramesMetadata: Encodable {
    let file: String
    // The joined segments'.
    let size: Int
    // FrameCodec's name.
    let encoding: String
    let width: Int
    let height: Int
    let pixelFormat: String
    let frameCount: Int
    // The rear's.
    let confidence: Confidence?
    let frames: [Frame]
    let dropped: [DroppedFrame]

    // depth_frames_confidence.bin.
    struct Confidence: Encodable {
        let file: String
        let size: Int
        let encoding: String
        let pixelFormat: String
    }

    // A delivered depth map; filtered, accuracy and quality are the front's, the confidence map's size and SHA-256 the rear's.
    struct Frame: Codable {
        let timestamp: Double
        let filtered: Bool?
        let accuracy: String?
        let quality: String?
        // The map as stored in the file, and the SHA-256 of its decoded bytes.
        let compressedSize: Int
        let rawSha256: String
        let confidenceCompressedSize: Int?
        let confidenceRawSha256: String?
    }
}

// color_intrinsics.json or depth_intrinsics.json.
private struct IntrinsicsFile: Encodable {
    let imageWidth: Int
    let imageHeight: Int
    let principalPointOrigin: PrincipalPointOrigin
    // Each frame's; null when it came without them.
    let frames: [Intrinsics?]
    // The front's.
    let distortions: [DistortionRanges]?
}

// A frame's intrinsic matrix, in its own pixels.
private struct Intrinsics: Codable {
    let fx: Float
    let fy: Float
    let cx: Float
    let cy: Float

    init(_ k: matrix_float3x3) {
        fx = k.columns.0.x
        fy = k.columns.1.y
        cx = k.columns.2.x
        cy = k.columns.2.y
    }

    init(fx: Float, fy: Float, cx: Float, cy: Float) {
        (self.fx, self.fy, self.cx, self.cy) = (fx, fy, cx, cy)
    }

    // Apple carries a frame's intrinsic matrix from its calibration's reference dimensions about pixel centers, the principal point of a frame scaled by s at (c + 0.5) * s - 0.5, where the depth intrinsics and the distortion centers are carried about the frame's corner, at c * s: this matrix carried so, its principal point moved by (1 - s) / 2.
    func carriedAboutCorner(scale: [Float]) -> Intrinsics {
        Intrinsics(fx: fx, fy: fy, cx: cx + (1 - scale[0]) / 2, cy: cy + (1 - scale[1]) / 2)
    }
}

// A front calibration's lens distortion for one image: the center carried from the calibration's reference dimensions to the image as the intrinsic matrix is, the radius-normalized lookup tables as they are; none when the calibration lacks a table.
private struct Distortion: Codable, Hashable {
    let center: [Float]
    let lookupTable: [Float]
    let inverseLookupTable: [Float]
    // The image's scale from the calibration's reference dimensions, x then y; nil in a line an app before 5.0.1 wrote.
    let scale: [Float]?

    init?(_ calibration: Calibration, width: Int, height: Int) {
        guard let lookupTable = calibration.lookupTable, let inverseLookupTable = calibration.inverseLookupTable else { return nil }
        let scaleX = Float(width) / Float(calibration.referenceDimensions.width)
        let scaleY = Float(height) / Float(calibration.referenceDimensions.height)
        center = [Float(calibration.distortionCenter.x) * scaleX, Float(calibration.distortionCenter.y) * scaleY]
        scale = [scaleX, scaleY]
        self.lookupTable = lookupTable
        self.inverseLookupTable = inverseLookupTable
    }
}

// A distortion in an intrinsics file, with the runs of frames it applies to.
private struct DistortionRanges: Encodable {
    let center: [Float]
    let lookupTable: [Float]
    let inverseLookupTable: [Float]
    let frameRanges: [[Int]]
}

// extrinsics.json.
private struct ExtrinsicsFile: Encodable {
    let depthToColor: [DepthToColor]
    // The rear's: each color frame's.
    let cameraPoses: [CameraPose]?
}

// A transform from the depth camera to the color camera, rows 0-2 row-major, with the runs of depth maps it applies to.
private struct DepthToColor: Encodable {
    let matrix: [[Float]]
    let depthFrameRanges: [[Int]]
}

// A rear color frame's pose in extrinsics.json: ARKit's tracking state and rows 0-2 of ARCamera.transform, row-major.
private struct CameraPose: Codable {
    let trackingState: String
    let worldFromCamera: [[Float]]

    init(_ pose: Pose) {
        trackingState = pose.trackingState
        // Row-major, while a simd matrix is indexed by column first.
        worldFromCamera = (0..<3).map { row in (0..<4).map { column in pose.worldFromCamera[column][row] } }
    }
}
