import Foundation

// Writes a POSIX ustar archive, streamed in chunks; a member of 8 GiB or more has its size in the GNU base-256 encoding, which tar and Python's tarfile read.
enum Tar {
    private static let blockSize = 512

    // Appends the files as root/<file name> to a partial archive after the members it already holds whole, deleting each file once it is in, then ends the archive; a pack cut short is resumed by calling this again.
    static func pack(_ files: [URL], root: String, into archive: URL) throws {
        if !FileManager.default.fileExists(atPath: archive.path) {
            guard FileManager.default.createFile(atPath: archive.path, contents: nil) else { throw RecorderError("cannot create \(archive.lastPathComponent)") }
        }
        let out = try FileHandle(forUpdating: archive)
        do {
            let stored = try completeMembers(out)
            for file in files {
                let path = root + "/" + file.lastPathComponent
                if !stored.contains(path) { try append(file, as: path, to: out) }
                // A file already stored may still be on disk when the previous pack stopped between storing and deleting it.
                if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            }
            try out.write(contentsOf: Data(count: 2 * blockSize))
        } catch {
            try? out.close()
            throw error
        }
        try out.close()
    }

    // The paths of the members stored whole; whatever follows the last of them is cut off and the handle is left at the end.
    private static func completeMembers(_ handle: FileHandle) throws -> Set<String> {
        let length = try handle.seekToEnd()
        var paths = Set<String>()
        var offset: UInt64 = 0
        while offset + UInt64(blockSize) <= length {
            try handle.seek(toOffset: offset)
            guard let header = try handle.read(upToCount: blockSize), header.count == blockSize, header.contains(where: { $0 != 0 }),
                  let size = size(ofHeader: [UInt8](header)) else { break }
            let end = offset + UInt64(blockSize + padded(size))
            guard end <= length else { break }
            paths.insert(String(decoding: header.prefix(100).prefix { $0 != 0 }, as: UTF8.self))
            offset = end
        }
        try handle.truncate(atOffset: offset)
        try handle.seek(toOffset: offset)
        return paths
    }

    private static func append(_ file: URL, as path: String, to out: FileHandle) throws {
        guard let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize else { throw RecorderError("\(file.lastPathComponent) has no size") }
        try out.write(contentsOf: header(path: path, size: size, mtime: Int(Date().timeIntervalSince1970)))
        let input = try FileHandle(forReadingFrom: file)
        var written = 0
        // Each chunk is released before the next is read: a file of several GB would otherwise stay in memory until iOS stops the app.
        while try autoreleasepool(invoking: { () throws -> Bool in
            guard let chunk = try input.read(upToCount: 8 << 20), !chunk.isEmpty else { return false }
            try out.write(contentsOf: chunk)
            written += chunk.count
            return true
        }) {}
        try input.close()
        guard written == size else { throw RecorderError("\(file.lastPathComponent) changed while packing") }
        try out.write(contentsOf: Data(count: padded(size) - size))
    }

    static func header(path: String, size: Int, mtime: Int) -> Data {
        precondition(path.utf8.count < 100)
        var block = [UInt8](repeating: 0, count: blockSize)
        func put(_ string: String, at offset: Int) {
            for (i, byte) in string.utf8.enumerated() { block[offset + i] = byte }
        }
        put(path, at: 0)
        put("0000644", at: 100)
        put("0000000", at: 108)
        put("0000000", at: 116)
        if size < 1 << 33 {
            put(octal(size, width: 11), at: 124)
        } else {
            block[124] = 0x80
            for i in 0..<11 { block[135 - i] = UInt8((size >> (8 * i)) & 0xff) }
        }
        put(octal(mtime, width: 11), at: 136)
        put("        ", at: 148)
        put("0", at: 156)
        put("ustar", at: 257)
        put("00", at: 263)
        put(octal(block.reduce(0) { $0 + Int($1) }, width: 6), at: 148)
        block[154] = 0
        block[155] = 0x20
        return Data(block)
    }

    private static func size(ofHeader header: [UInt8]) -> Int? {
        let field = header[124..<136]
        if header[124] & 0x80 != 0 { return field.dropFirst().reduce(0) { $0 << 8 | Int($1) } }
        return Int(String(decoding: field.prefix { $0 != 0 && $0 != 0x20 }, as: UTF8.self), radix: 8)
    }

    private static func octal(_ value: Int, width: Int) -> String {
        let digits = String(value, radix: 8)
        return String(repeating: "0", count: width - digits.count) + digits
    }

    private static func padded(_ size: Int) -> Int { (size + blockSize - 1) / blockSize * blockSize }
}
