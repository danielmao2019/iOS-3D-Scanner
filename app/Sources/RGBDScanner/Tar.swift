import Foundation

// A POSIX ustar archive of files, built as it is streamed and never stored: each file as root/<file name>, a header, its bytes and zero padding to a whole block, then two zero blocks; a member of 8 GiB or more has its size in the GNU base-256 encoding, which tar and Python's tarfile read.
enum Tar {
    private static let blockSize = 512

    // The archive's size in bytes, from the files' sizes.
    static func size(of files: [URL]) throws -> Int {
        try files.reduce(2 * blockSize) { total, file in try total + blockSize + padded(attributes(of: file).size) }
    }

    // Hands the archive's bytes to send in order, in chunks of at most 8 MiB; each member's mtime is its file's modification date, so every call streams the same bytes while the files stay as they are. Fails if a file's size changes while it is read.
    static func stream(_ files: [URL], root: String, to send: (Data) throws -> Void) throws {
        for file in files {
            let (size, mtime) = try attributes(of: file)
            try send(header(path: root + "/" + file.lastPathComponent, size: size, mtime: mtime))
            let input = try FileHandle(forReadingFrom: file)
            var read = 0
            // Each chunk is released before the next is read: a file of several GB would otherwise stay in memory until iOS stops the app.
            while try autoreleasepool(invoking: { () throws -> Bool in
                guard let chunk = try input.read(upToCount: 8 << 20), !chunk.isEmpty else { return false }
                read += chunk.count
                try send(chunk)
                return true
            }) {}
            try input.close()
            guard read == size else { throw RecorderError("\(file.lastPathComponent) changed while it was sent") }
            try send(Data(count: padded(size) - size))
        }
        try send(Data(count: 2 * blockSize))
    }

    // A file's size and modification date in whole seconds since 1970.
    private static func attributes(of file: URL) throws -> (size: Int, mtime: Int) {
        let values = try file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard let size = values.fileSize, let modified = values.contentModificationDate else { throw RecorderError("\(file.lastPathComponent) has no size or modification date") }
        return (size, Int(modified.timeIntervalSince1970))
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

    private static func octal(_ value: Int, width: Int) -> String {
        let digits = String(value, radix: 8)
        return String(repeating: "0", count: width - digits.count) + digits
    }

    private static func padded(_ size: Int) -> Int { (size + blockSize - 1) / blockSize * blockSize }
}
