/// Selects only the mutants within the range of a Git diff.
public enum DiffFilter {
    /// Keeps only the mutants whose rewritten part (`point`) has a line range that intersects
    /// the changed line ranges (1-based, inclusive at both ends).
    public static func filter(_ mutants: [Mutant], changedLines: [ClosedRange<Int>]) -> [Mutant] {
        mutants.filter { m in
            let span = m.start.line...max(m.start.line, m.end.line)
            return changedLines.contains { $0.overlaps(span) }
        }
    }

    /// Keeps only the mutants whose rewritten part (`point`) intersects the changed byte ranges.
    public static func filter(_ mutants: [Mutant], changedByteRanges: [ByteRange]) -> [Mutant] {
        mutants.filter { m in changedByteRanges.contains { $0.overlaps(m.point) } }
    }

    /// From the output of `git diff --unified=0`, extracts the added/changed line ranges for each post-change file path.
    ///
    /// For a hunk that only deletes lines (`+c,0`), the lines before and after the deletion point (`c` and `c+1`) are treated as changed.
    /// Deleted files (`+++ /dev/null`) are not included.
    ///
    /// The lines of a hunk are skipped by the counts of its header, so that an added line whose text starts with
    /// `++ ` or `@@` is not read as a header. Paths that git quotes (`"b/a\tb.swift"`, or non-ASCII bytes as octal
    /// escapes when `core.quotePath` is on) are unquoted. A file that git reports as binary (`*.swift -diff` in
    /// `.gitattributes`) has no hunks; it counts as changed in every line.
    public static func parseUnifiedDiff(_ diff: String) -> [String: [ClosedRange<Int>]] {
        var result: [String: [ClosedRange<Int>]] = [:]
        var currentPath: String?
        var oldRemaining = 0
        var newRemaining = 0
        func destination(_ raw: Substring) -> String? {
            var path = unquote(String(raw))
            if path == "/dev/null" { return nil }
            if let tab = path.firstIndex(of: "\t") { path = String(path[..<tab]) }
            // `b/` is the prefix the tool asks git for; the others are what `diff.mnemonicPrefix` makes of it
            for prefix in ["b/", "w/", "i/", "c/", "o/"] where path.hasPrefix(prefix) { return String(path.dropFirst(2)) }
            return path
        }
        for rawLine in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.hasSuffix("\r") ? rawLine.dropLast() : rawLine
            if oldRemaining > 0 || newRemaining > 0 {
                if line.hasPrefix("-"), oldRemaining > 0 { oldRemaining -= 1; continue }
                if line.hasPrefix("+"), newRemaining > 0 { newRemaining -= 1; continue }
                if line.hasPrefix("\\") { continue }
                // Not a line of the hunk after all: read it as a header
                oldRemaining = 0
                newRemaining = 0
            }
            if line.hasPrefix("\\") { continue }
            if line.hasPrefix("+++ ") {
                currentPath = destination(line.dropFirst(4))
                if let path = currentPath { result[path, default: []] = result[path, default: []] }
                continue
            }
            if line.hasPrefix("Binary files "), line.hasSuffix(" differ") {
                // `Binary files a/x.swift and b/x.swift differ`: no line information, so every line
                let text = Array(line.dropLast(" differ".count))
                let separator = Array(" and ")
                var index = text.count - separator.count
                while index > 0, Array(text[index..<(index + separator.count)]) != separator { index -= 1 }
                if index > 0, let path = destination(Substring(String(text[(index + separator.count)...]))) { result[path] = [1...Int.max] }
                continue
            }
            guard line.hasPrefix("@@"), let path = currentPath else { continue }
            // @@ -a,b +c,d @@
            let fields = line.split(separator: " ")
            guard let plus = fields.first(where: { $0.hasPrefix("+") }) else { continue }
            let numbers = plus.dropFirst().split(separator: ",")
            guard let start = Int(numbers.first ?? "") else { continue }
            let count = numbers.count > 1 ? Int(numbers[1]) ?? 1 : 1
            if let minus = fields.first(where: { $0.hasPrefix("-") }) {
                let old = minus.dropFirst().split(separator: ",")
                oldRemaining = old.count > 1 ? Int(old[1]) ?? 1 : 1
            }
            newRemaining = count
            if count == 0 {
                result[path, default: []].append(max(1, start)...(start + 1))
            } else {
                result[path, default: []].append(start...(start + count - 1))
            }
        }
        return result
    }

    /// A path as git prints it when it contains bytes it quotes: `"dir/\347\224\273.swift"` → `dir/画.swift`.
    /// Text that is not in double quotes is returned as it is.
    public static func unquote(_ text: String) -> String {
        guard text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") else { return text }
        var bytes: [UInt8] = []
        var iterator = Array(text.utf8.dropFirst().dropLast()).makeIterator()
        while let byte = iterator.next() {
            guard byte == UInt8(ascii: "\\"), let escape = iterator.next() else {
                bytes.append(byte)
                continue
            }
            switch escape {
            case UInt8(ascii: "n"): bytes.append(0x0A)
            case UInt8(ascii: "t"): bytes.append(0x09)
            case UInt8(ascii: "r"): bytes.append(0x0D)
            case UInt8(ascii: "a"): bytes.append(0x07)
            case UInt8(ascii: "b"): bytes.append(0x08)
            case UInt8(ascii: "f"): bytes.append(0x0C)
            case UInt8(ascii: "v"): bytes.append(0x0B)
            case UInt8(ascii: "0")...UInt8(ascii: "7"):
                var value = Int(escape - UInt8(ascii: "0"))
                for _ in 0..<2 {
                    guard let digit = iterator.next(), (UInt8(ascii: "0")...UInt8(ascii: "7")).contains(digit) else { break }
                    value = value * 8 + Int(digit - UInt8(ascii: "0"))
                }
                bytes.append(UInt8(truncatingIfNeeded: value))
            default:
                bytes.append(escape)
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
