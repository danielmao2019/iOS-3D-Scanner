import Foundation

// Writes a POSIX ustar archive holding one directory's regular files, streamed in chunks, under a top directory named after the archive.
enum Tar {
    static func pack(directory: URL, into archive: URL) throws {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        FileManager.default.createFile(atPath: archive.path, contents: nil)
        let out = try FileHandle(forWritingTo: archive)
        defer { out.closeFile() }
        let mtime = Int(Date().timeIntervalSince1970)
        let root = archive.deletingPathExtension().lastPathComponent

        for file in files {
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            let path = root + "/" + file.lastPathComponent
            out.write(header(path: path, size: size, mtime: mtime))
            let input = try FileHandle(forReadingFrom: file)
            var written = 0
            while true {
                let chunk = input.readData(ofLength: 8 << 20)
                if chunk.isEmpty { break }
                out.write(chunk)
                written += chunk.count
            }
            input.closeFile()
            guard written == size else { throw RecorderError("\(file.lastPathComponent) changed while packing") }
            let pad = (512 - size % 512) % 512
            if pad > 0 { out.write(Data(count: pad)) }
        }
        out.write(Data(count: 1024))
    }

    private static func header(path: String, size: Int, mtime: Int) -> Data {
        precondition(path.utf8.count < 100 && size < 0o77777777777)
        var block = [UInt8](repeating: 0, count: 512)
        func put(_ string: String, at offset: Int) {
            for (i, byte) in string.utf8.enumerated() { block[offset + i] = byte }
        }
        put(path, at: 0)
        put("0000644", at: 100)
        put("0000000", at: 108)
        put("0000000", at: 116)
        put(String(format: "%011o", size), at: 124)
        put(String(format: "%011o", mtime), at: 136)
        put("        ", at: 148)
        put("0", at: 156)
        put("ustar", at: 257)
        put("00", at: 263)
        let checksum = block.reduce(0) { $0 + Int($1) }
        put(String(format: "%06o", checksum), at: 148)
        block[154] = 0
        block[155] = 0x20
        return Data(block)
    }
}
