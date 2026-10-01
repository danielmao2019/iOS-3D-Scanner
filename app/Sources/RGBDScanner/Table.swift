import Foundation

// A color.csv or depth.csv: a header, then one row per frame delivered or dropped, "index,timestamp,dropped,..." with index -1 on a dropped row.
struct Table {
    // The delivered frames, and the first and last timestamps of all rows.
    private(set) var frames = 0
    private(set) var first = Double.infinity
    private(set) var last = -Double.infinity
    private let header: Substring
    private var rows: [[Substring]] = []

    init(_ text: String, name: String) throws {
        let lines = text.split(separator: "\n")
        guard let header = lines.first else { throw RecorderError("\(name) has no header") }
        self.header = header
        for line in lines.dropFirst() {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count >= 3, let index = Int(fields[0]), let time = Double(fields[1]), index == (fields[0] == "-1" ? -1 : frames) else {
                throw RecorderError("bad row in \(name): \(line)")
            }
            if index != -1 { frames += 1 }
            first = min(first, time)
            last = max(last, time)
            rows.append(fields)
        }
    }

    init(contentsOf url: URL) throws {
        try self.init(String(contentsOf: url, encoding: .utf8), name: url.lastPathComponent)
    }

    // This table with every delivered row from the given index on turned into a dropped row with the reason, keeping its timestamp and emptying its other cells.
    func dropping(from index: Int, reason: String) -> Table {
        precondition(index <= frames, "cannot keep \(index) of \(frames) delivered frames")
        var table = self
        table.frames = index
        table.rows = rows.map { fields in
            guard let i = Int(fields[0]), i >= index else { return fields }
            return ["-1", fields[1], Substring(reason)] + Array(repeating: "", count: fields.count - 3)
        }
        return table
    }

    var text: String {
        ([header] + rows.map { $0.joined(separator: ",")[...] }).joined(separator: "\n") + "\n"
    }
}
