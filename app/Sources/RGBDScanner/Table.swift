import Foundation

// A color.csv or depth.csv: a header, then one row per frame delivered or dropped, "index,timestamp,dropped,..." with index -1 on a dropped row.
struct Table {
    // The delivered frames, and the first and last timestamps of all rows.
    private(set) var frames = 0
    private(set) var first = Double.infinity
    private(set) var last = -Double.infinity

    init(_ text: String, name: String) throws {
        let lines = text.split(separator: "\n")
        guard !lines.isEmpty else { throw RecorderError("\(name) has no header") }
        for line in lines.dropFirst() {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count >= 3, let index = Int(fields[0]), let time = Double(fields[1]), index == (fields[0] == "-1" ? -1 : frames) else {
                throw RecorderError("bad row in \(name): \(line)")
            }
            if index != -1 { frames += 1 }
            first = min(first, time)
            last = max(last, time)
        }
    }

    init(contentsOf url: URL) throws {
        try self.init(String(contentsOf: url, encoding: .utf8), name: url.lastPathComponent)
    }
}
