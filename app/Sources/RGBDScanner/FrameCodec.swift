import CryptoKit
import Foundation
import zlib

// How a recording stores a frame losslessly: its bytes, for a color frame first filtered, as one raw DEFLATE stream (RFC 1951), with the SHA-256 of the bytes as the camera delivered them, against which the reader checks that decoding gives them back.
enum FrameCodec {
    // A 420f color frame, its luma plane's height rows then its CbCr plane's height / 2 rows, each width bytes: every row after a plane's first is replaced by its bytewise difference, mod 256, from the row above in its plane, which leaves small values that zlib's run-length strategy codes in about a third of the frame's bytes (measured on the iPhone 13 Pro Max's frames).
    case color(width: Int, height: Int)
    // A depth or confidence map, deflated as it is.
    case map

    // As the frames metadata's encoding names it.
    var name: String {
        switch self {
        case .color: return "row_delta_deflate"
        case .map: return "deflate"
        }
    }

    // The frame as stored, and the SHA-256 of its bytes as delivered.
    struct Encoded {
        let bytes: Data
        let rawSHA256: String
    }

    // Encodes the frame whose bytes are raw, filtering them in place.
    func encode(_ raw: UnsafeMutableRawBufferPointer) -> Encoded {
        let rawSHA256 = SHA256.hash(data: UnsafeRawBufferPointer(raw)).hex
        switch self {
        case .color(let width, let height):
            precondition(raw.count == width * height * 3 / 2, "a \(raw.count)-byte color frame is not \(width)×\(height) 420f")
            let bytes = raw.bindMemory(to: UInt8.self)
            Self.deltaRows(bytes.baseAddress!, rows: height, width: width)
            Self.deltaRows(bytes.baseAddress! + width * height, rows: height / 2, width: width)
            // Delta-coded camera rows have few repeats beyond runs, so the run-length strategy codes them smaller and several times faster than zlib's default matching.
            return Encoded(bytes: Self.deflate(UnsafeRawBufferPointer(raw), level: 1, strategy: Z_RLE), rawSHA256: rawSHA256)
        case .map:
            return Encoded(bytes: Self.deflate(UnsafeRawBufferPointer(raw), level: 1, strategy: Z_DEFAULT_STRATEGY), rawSHA256: rawSHA256)
        }
    }

    // Replaces each of the plane's rows after the first by its difference from the row above, bottom row first so every row is taken from the original above it.
    private static func deltaRows(_ plane: UnsafeMutablePointer<UInt8>, rows: Int, width: Int) {
        for row in stride(from: rows - 1, through: 1, by: -1) {
            let current = plane + row * width
            let above = current - width
            for x in 0..<width { current[x] = current[x] &- above[x] }
        }
    }

    // The bytes as one raw DEFLATE stream.
    private static func deflate(_ input: UnsafeRawBufferPointer, level: Int32, strategy: Int32) -> Data {
        var stream = z_stream()
        // windowBits -15 makes a raw stream, without zlib's header and checksum; memLevel 9 is the fastest.
        var status = deflateInit2_(&stream, level, Z_DEFLATED, -15, 9, strategy, zlibVersion(), Int32(MemoryLayout<z_stream>.size))
        precondition(status == Z_OK, "deflateInit2 failed: \(status)")
        defer { deflateEnd(&stream) }
        var output = Data(count: Int(deflateBound(&stream, uLong(input.count))))
        output.withUnsafeMutableBytes { out in
            stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress!)
            stream.avail_in = uInt(input.count)
            stream.next_out = out.bindMemory(to: Bytef.self).baseAddress!
            stream.avail_out = uInt(out.count)
            // deflateBound leaves room for the whole stream, so one call finishes it.
            status = zlib.deflate(&stream, Z_FINISH)
        }
        precondition(status == Z_STREAM_END, "deflate did not finish within deflateBound: \(status)")
        output.count = Int(stream.total_out)
        return output
    }
}
