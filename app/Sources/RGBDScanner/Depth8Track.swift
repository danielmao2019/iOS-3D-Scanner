import AVFoundation

// An 8-bit H.264 depth track encoded the way an earlier app stored front-camera depth at one of its commits, so offline ablations can measure what each of its steps loses against depth.bin.
// The earlier app's front-camera depth connection was .portrait and mirrored, so each depth map is laid out as it received it: turned 90° clockwise, as the upright rotation of the phone held in portrait turns it, then mirrored left to right (UIImage.Orientation .leftMirrored, as the depth view shows it), which together transpose it to 480 wide, 640 high; then quantized as code = UInt8(min(max(z / 2.0, 0), 1) * 255): 2 m and beyond → 255, and NaN or z <= 0 → 0 (the earliest commit crashed on NaN, which the unfiltered stream delivers). Row j of the codes goes into a new OneComponent8 buffer bufferWidth wide at byte j * the buffer row stride, and the buffer through a pixel-buffer adaptor (OneComponent8, the map's width and height) into an H.264 input with only codec, width and height set, the encoder's defaults otherwise.
final class Depth8Track {
    static let rangeMetres: Float = 2.0
    static let layout = "portrait_mirrored"
    static let pixelMapping = "track pixel (row r, column c) is depth map pixel (row c, column r): the map turned 90° clockwise, then mirrored left to right, a transpose"

    // How far apart the earlier app took rows: a map's width (floats or bytes), ignoring padding, or the buffer's bytes per row.
    enum Rows: String {
        case width
        case bytesPerRow = "bytes_per_row"
    }

    let file: String
    // How this track reads the depth map's rows; the caller hands it the codes read that way.
    let sourceRows: Rows
    private let reproduces: String
    private let width: Int
    private let height: Int
    private let bufferWidth: Int
    private let bufferRows: Rows
    private let bufferBytesPerRow: Int
    private let bufferRowStride: Int
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    // Set on the queue that appends, once the writer fails; read once the track has finished.
    private(set) var error: String?

    // width × height is the portrait map; the writer starts at once, its session at time zero.
    init(directory: URL, file: String, reproduces: String, width: Int, height: Int, sourceRows: Rows, bufferWidth: Int, bufferRows: Rows) throws {
        precondition(bufferWidth >= width, "a \(bufferWidth)-wide buffer cannot hold a \(width)-wide map")
        self.file = file
        self.reproduces = reproduces
        self.width = width
        self.height = height
        self.sourceRows = sourceRows
        self.bufferWidth = bufferWidth
        self.bufferRows = bufferRows
        writer = try AVAssetWriter(outputURL: directory.appendingPathComponent(file), fileType: .mov)
        // So a recording cut off by a closed app keeps the track up to its last fragment.
        writer.movieFragmentInterval = CMTime(value: 1, timescale: 1)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        // Fine enough that each sample keeps its depth.csv time to 11 µs.
        input.mediaTimeScale = 90_000
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_OneComponent8,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        guard writer.canAdd(input) else { throw RecorderError("cannot add the \(file) writer input") }
        writer.add(input)
        bufferBytesPerRow = CVPixelBufferGetBytesPerRow(Self.makeBuffer(width: bufferWidth, height: height))
        bufferRowStride = bufferRows == .width ? bufferWidth : bufferBytesPerRow
        precondition(bufferRowStride <= bufferBytesPerRow, "rows \(bufferRowStride) bytes apart overrun a buffer of \(bufferBytesPerRow)-byte rows")
        guard writer.startWriting() else { throw writer.error ?? RecorderError("cannot start writing \(file)") }
        writer.startSession(atSourceTime: .zero)
    }

    // Describes the track for metadata.json.
    var described: [String: Any] {
        [
            "file": file,
            "reproduces": reproduces,
            "encoded_width": width,
            "encoded_height": height,
            "source_rows": sourceRows.rawValue,
            "buffer_width": bufferWidth,
            "buffer_bytes_per_row": bufferBytesPerRow,
            "buffer_rows": bufferRows.rawValue,
            "buffer_row_stride_bytes": bufferRowStride,
        ]
    }

    // The codes of mapWidth × mapHeight Float32 metres, rows packed, in the portrait mirrored layout: track pixel (r, c) is map pixel (c, r).
    static func codes(_ map: Data, mapWidth: Int, mapHeight: Int) -> [UInt8] {
        precondition(map.count == mapWidth * mapHeight * 4, "\(map.count) bytes is not a \(mapWidth)×\(mapHeight) Float32 map")
        var codes = [UInt8](repeating: 0, count: mapWidth * mapHeight)
        map.withUnsafeBytes { raw in
            let z = raw.bindMemory(to: Float32.self)
            codes.withUnsafeMutableBufferPointer { out in
                for r in 0..<mapWidth {
                    for c in 0..<mapHeight {
                        let v = z[c * mapWidth + r]
                        out[r * mapHeight + c] = v.isNaN || v <= 0 ? 0 : UInt8(min(max(v / 2.0, 0), 1) * 255)
                    }
                }
            }
        }
        return codes
    }

    // Writes the portrait codes into a new buffer, zeroed first, and appends it at the time; waits while the encoder is busy, so the track keeps every depth map.
    func append(_ codes: [UInt8], at time: CMTime) {
        precondition(codes.count == width * height, "\(codes.count) codes for a \(width)×\(height) track")
        guard error == nil else { return }
        let buffer = Self.makeBuffer(width: bufferWidth, height: height)
        precondition(CVPixelBufferGetBytesPerRow(buffer) == bufferBytesPerRow, "buffer rows changed from \(bufferBytesPerRow) to \(CVPixelBufferGetBytesPerRow(buffer)) bytes")
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = CVPixelBufferGetBaseAddress(buffer)!
        memset(base, 0, bufferBytesPerRow * height)
        codes.withUnsafeBytes { src in
            for j in 0..<height {
                memcpy(base.advanced(by: j * bufferRowStride), src.baseAddress!.advanced(by: j * width), width)
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        while !input.isReadyForMoreMediaData && writer.status == .writing { usleep(1000) }
        guard writer.status == .writing, adaptor.append(buffer, withPresentationTime: time) else {
            error = writer.error?.localizedDescription ?? "the writer did not take the frame at \(CMTimeGetSeconds(time)) s"
            return
        }
    }

    // Finishes the track, then calls done on any queue.
    func finish(_ done: @escaping () -> Void) {
        guard writer.status == .writing else {
            error = error ?? writer.error?.localizedDescription ?? "the writer stopped"
            return done()
        }
        input.markAsFinished()
        writer.finishWriting { [self] in
            if writer.status == .failed { error = writer.error?.localizedDescription ?? "the writer failed" }
            done()
        }
    }

    private static func makeBuffer(width: Int, height: Int) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_OneComponent8, nil, &buffer)
        guard status == kCVReturnSuccess, let buffer else { preconditionFailure("cannot create a \(width)×\(height) OneComponent8 buffer: \(status)") }
        return buffer
    }
}
