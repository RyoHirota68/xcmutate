/// Embeds all mutants into the source as expression-level switches (mutant schemata).
///
/// - Switch form: `(__xcmutate.isOn(1) ? (mutated version 1) : __xcmutate.isOn(2) ? (mutated version 2) : (original expression))`
/// - Nesting is assembled from the inside out. Inner switches go only on the original-expression side; the mutated side is
///   "the original expression + the change of that one mutant only" (correct because only one mutant is ever active at a time).
/// - Done by text splicing (UTF-8 bytes) without adding newlines. The helper is appended at the end of the file,
///   so line numbers before the helper match the original source.
public enum Instrumenter {
    public static let helperTypeName = ToolNaming.helperTypeName
    public static let environmentVariable = ToolNaming.environmentPrefix + "ACTIVE"
    /// Environment variable that passes the path of the file to which reach/activation records are appended. Nothing is recorded if absent.
    public static let traceEnvironmentVariable = ToolNaming.environmentPrefix + "TRACE"
    /// When this is set, reach records become "per test" (used only for the baseline). The test process's standard error is
    /// directed to the record file so that test-start lines (XCTest's `Test Case '-[…]' started.`, Swift Testing's
    /// `◇ Test … started.`) and reach lines (`__xcmutate R <ID>`) appear in order in a single file.
    /// A reach line is written again on the first evaluation after someone else (i.e. a test-start line or the like) has written to the file
    /// (same idea as SupportDeclarations.swift in ericodx/swift-mutation-testing; MIT License).
    public static let testTraceEnvironmentVariable = ToolNaming.environmentPrefix + "TRACE_TESTS"
    /// Prefix of reach lines in per-test records.
    public static let testTraceMarker = ToolNaming.helperTypeName
    /// Environment variable that passes the path of the shared region (`--shared-process`): a file that the test
    /// process maps into memory. When it is set, the active mutant is read from the region at every evaluation, so a
    /// driver inside the test process can switch mutants without a new process, and evaluations are counted in the
    /// region instead of being written to the record file. Layout (64-bit integers): `[0]` the active mutant ID (-1: none),
    /// `[1]` the number of evaluations as active, `[2]` the number of counters, `[3]` reserved, `[4 + ID]` the number of
    /// evaluations of the switch `ID`.
    public static let sharedEnvironmentVariable = ToolNaming.environmentPrefix + "SHARED"
    /// Number of 64-bit integers before the per-switch counters in the shared region.
    public static let sharedHeaderCount = 4
    public static let helperMarker = ToolNaming.helperMarker

    /// The names of the environment variables that one embedding reads.
    ///
    /// `run` gives every embedding a token and puts it into the names (`XCMUTATE_ACTIVE_<token>`). A test
    /// process hands its environment to the child processes it starts. A child built from the same embedding (the
    /// product's own executable) reads the same names and has the same mutant on, as it must; a child that holds
    /// another embedding (a program that a test instruments and compiles itself, or another project's build) reads
    /// other names and is not affected. Without a token (`instrument`, and the tool's own tests) the names are plain.
    public struct EnvironmentNames: Sendable, Equatable {
        public let token: String
        public let active: String
        public let trace: String
        public let testTrace: String
        public let shared: String

        public init(token: String = "") {
            self.token = token
            let suffix = token.isEmpty ? "" : "_" + token
            active = Instrumenter.environmentVariable + suffix
            trace = Instrumenter.traceEnvironmentVariable + suffix
            testTrace = Instrumenter.testTraceEnvironmentVariable + suffix
            shared = Instrumenter.sharedEnvironmentVariable + suffix
        }

        /// A token for the embedding that `run` makes in a work directory: the same for every build in that
        /// directory, different between directories (upper-case letters and digits, valid in a variable name).
        public static func token(forWorkDirectory path: String) -> String {
            var hash: UInt64 = 0xcbf2_9ce4_8422_2325
            for byte in path.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 0x0000_0100_0000_01b3
            }
            return String(hash, radix: 36, uppercase: true)
        }
    }

    public static func switchCall(_ id: Int) -> String { "\(helperTypeName).isOn(\(id))" }

    /// Returns the text with the mutants embedded. Returns the original text unchanged if there are no mutants.
    public static func instrument(source: String, mutants: [Mutant], names: EnvironmentNames = EnvironmentNames()) -> String {
        instrumentWithBranches(source: source, mutants: mutants, names: names).text
    }

    /// The instrumented text, and the byte range in the output where each mutant's mutated branch lies.
    /// Used to identify the offending mutant, down to the column, from the position (line and column) of a compiler diagnostic.
    public static func instrumentWithBranches(source: String, mutants: [Mutant], names: EnvironmentNames = EnvironmentNames()) -> (text: String, branches: [Int: ByteRange]) {
        guard !mutants.isEmpty else { return (source, [:]) }
        let bytes = Array(source.utf8)
        let forest = RegionForest(mutants: mutants)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count * 2)
        var branches: [Int: ByteRange] = [:]
        render(range: ByteRange(start: 0, end: bytes.count), children: forest.roots, bytes: bytes, into: &out, branches: &branches)

        var result = String(decoding: out, as: UTF8.self)
        // By bytes ("\r\n" is one `Character`, not "\n"); a file that ends without a line break gets its own kind
        if let last = out.last, last != UInt8(ascii: "\n"), last != UInt8(ascii: "\r") { result += Self.usesCRLF(source) ? "\r\n" : "\n" }
        result += helperSource(names: names)
        return (result, branches)
    }

    /// Whether the first line break of the text is CRLF.
    static func usesCRLF(_ source: String) -> Bool {
        var previous: UInt8 = 0
        for byte in source.utf8 {
            if byte == UInt8(ascii: "\n") { return previous == UInt8(ascii: "\r") }
            previous = byte
        }
        return false
    }

    /// The helper appended at the end of the file.
    ///
    /// - `nonisolated`: callable from any context even in targets whose default actor isolation is MainActor
    /// - The environment variable is read only once at startup; after that only integer comparisons are done (a lesson from Muter PR #318)
    /// - **No import is added**: adding `import Foundation` would conflict in access level with the imports in other files of the same module
    ///   (`fileprivate import` vs. plain `import`, plain `import` vs. `internal import`) and cause the error
    ///   "ambiguous implicit access level for import of 'Foundation'". So the C functions used for reading the environment variable,
    ///   appending to the file and locking (`getenv` `fopen` `fputs` `fflush` `os_unfair_lock_*`) are
    ///   declared with `@_silgen_name` and called (arguments and return values are only pointers and integers)
    /// - Recording (only when `XCMUTATE_TRACE` is set): the first time a switch is evaluated,
    ///   one line is appended: `R <ID>` (reached) or `A <ID>` (evaluated as active). Written only once per ID.
    ///   When not recording, the extra cost is a single nil check of a `static let` determined at startup
    public static func helperSource(importFoundation: Bool = false, names: EnvironmentNames = EnvironmentNames()) -> String {
        let p = helperTypeName
        let lines = [
            helperMarker,
            "@_silgen_name(\"getenv\") nonisolated fileprivate func \(p)Getenv(_ name: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?",
            "@_silgen_name(\"fopen\") nonisolated fileprivate func \(p)Fopen(_ path: UnsafePointer<CChar>, _ mode: UnsafePointer<CChar>) -> OpaquePointer?",
            "@_silgen_name(\"fputs\") nonisolated fileprivate func \(p)Fputs(_ s: UnsafePointer<CChar>, _ file: OpaquePointer) -> Int32",
            "@_silgen_name(\"fflush\") nonisolated fileprivate func \(p)Fflush(_ file: OpaquePointer) -> Int32",
            "@_silgen_name(\"os_unfair_lock_lock\") nonisolated fileprivate func \(p)Lock(_ lock: UnsafeMutablePointer<UInt32>)",
            "@_silgen_name(\"os_unfair_lock_unlock\") nonisolated fileprivate func \(p)Unlock(_ lock: UnsafeMutablePointer<UInt32>)",
            "@_silgen_name(\"open\") nonisolated fileprivate func \(p)Open(_ path: UnsafePointer<CChar>, _ flags: Int32) -> Int32",
            "@_silgen_name(\"dup2\") nonisolated fileprivate func \(p)Dup2(_ from: Int32, _ to: Int32) -> Int32",
            "@_silgen_name(\"lseek\") nonisolated fileprivate func \(p)Lseek(_ fd: Int32, _ offset: Int64, _ whence: Int32) -> Int64",
            "@_silgen_name(\"write\") nonisolated fileprivate func \(p)Write(_ fd: Int32, _ bytes: UnsafeRawPointer, _ count: Int) -> Int",
            "@_silgen_name(\"mmap\") nonisolated fileprivate func \(p)Mmap(_ address: UnsafeMutableRawPointer?, _ length: Int, _ protection: Int32, _ flags: Int32, _ fd: Int32, _ offset: Int64) -> UnsafeMutableRawPointer?",
            "nonisolated fileprivate enum \(p) {",
            "    static let shared: \(p)Shared? = \(p)Getenv(\"\(names.shared)\").flatMap { \(p)Shared(path: String(cString: $0)) }",
            "    static let active: Int = \(p)Getenv(\"\(names.active)\").flatMap { Int(String(cString: $0)) } ?? -1",
            "    static let trace: \(p)Trace? = \(p)Getenv(\"\(names.trace)\").flatMap { \(p)Trace(path: String(cString: $0)) }",
            "    @inline(__always) static func isOn(_ id: Int) -> Bool {",
            "        if let s = shared { return s.evaluate(id) }",
            "        if let t = trace { t.record(id, active: id == active) }",
            "        return id == active",
            "    }",
            "}",
            "nonisolated fileprivate final class \(p)Shared: @unchecked Sendable {",
            "    private let cells: UnsafeMutablePointer<Int>",
            "    private let lock: UnsafeMutablePointer<UInt32>",
            "    init?(path: String) {",
            "        let descriptor = \(p)Open(path, 2)",
            "        guard descriptor >= 0 else { return nil }",
            "        let size = \(p)Lseek(descriptor, 0, 2)",
            "        guard size >= \(sharedHeaderCount * 8), let memory = \(p)Mmap(nil, Int(size), 3, 1, descriptor, 0), Int(bitPattern: memory) != -1 else { return nil }",
            "        cells = memory.assumingMemoryBound(to: Int.self)",
            "        lock = UnsafeMutablePointer<UInt32>.allocate(capacity: 1)",
            "        lock.initialize(to: 0)",
            "    }",
            "    func evaluate(_ id: Int) -> Bool {",
            "        let on = cells[0] == id",
            "        \(p)Lock(lock)",
            "        if id >= 0, id < cells[2] { cells[\(sharedHeaderCount) + id] &+= 1 }",
            "        if on { cells[1] &+= 1 }",
            "        \(p)Unlock(lock)",
            "        return on",
            "    }",
            "}",
            "nonisolated fileprivate final class \(p)Trace: @unchecked Sendable {",
            "    private let file: OpaquePointer",
            "    private let lock: UnsafeMutablePointer<UInt32>",
            "    private var seen = Set<Int>()",
            "    private var descriptor: Int32 = -1",
            "    private var size: Int64 = -1",
            "    init?(path: String) {",
            "        guard !path.isEmpty, let file = \(p)Fopen(path, \"a\") else { return nil }",
            "        self.file = file",
            "        lock = UnsafeMutablePointer<UInt32>.allocate(capacity: 1)",
            "        lock.initialize(to: 0)",
            "        if \(p)Getenv(\"\(names.testTrace)\") != nil {",
            "            descriptor = \(p)Open(path, 9)",
            "            if descriptor >= 0 { _ = \(p)Dup2(descriptor, 2) }",
            "        }",
            "    }",
            "    func record(_ id: Int, active: Bool) {",
            "        \(p)Lock(lock)",
            "        defer { \(p)Unlock(lock) }",
            "        if descriptor >= 0 {",
            "            if \(p)Lseek(descriptor, 0, 2) != size { seen.removeAll(keepingCapacity: true) }",
            "            if seen.insert(id).inserted {",
            "                let line = \"\\n\(testTraceMarker) R \" + String(id) + \"\\n\"",
            "                _ = line.withCString { \(p)Write(descriptor, $0, line.utf8.count) }",
            "            }",
            "            size = \(p)Lseek(descriptor, 0, 2)",
            "            return",
            "        }",
            "        guard seen.insert(id).inserted else { return }",
            "        _ = \(p)Fputs((active ? \"A \" : \"R \") + String(id) + \"\\n\", file)",
            "        _ = \(p)Fflush(file)",
            "    }",
            "}",
            "",
        ]
        return lines.joined(separator: "\n")
    }

    /// Whether the file already imports Foundation (including imports with an access level).
    /// If it does, the helper's import is not added (importing twice in the same file can produce a warning).
    static func importsFoundation(_ source: String) -> Bool {
        for line in source.split(whereSeparator: \.isNewline) {
            let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard let importIndex = words.firstIndex(of: "import"), importIndex + 1 < words.count else { continue }
            let leading = words[..<importIndex]
            let allowedLeading: Set<Substring> = [
                "@preconcurrency", "@_exported", "@testable", "@_implementationOnly",
                "public", "package", "internal", "fileprivate", "private",
            ]
            guard leading.allSatisfy({ allowedLeading.contains($0) || $0.hasPrefix("@") }) else { continue }
            let module = words[importIndex + 1]
            // A partial import such as `import struct Foundation.Date` does not make ProcessInfo visible, so it is not counted.
            if module == "Foundation" || module.hasPrefix("Foundation.") { return true }
        }
        return false
    }

    private static func render(range: ByteRange, children: [RegionNode], bytes: [UInt8], into out: inout [UInt8], branches: inout [Int: ByteRange]) {
        var cursor = range.start
        for child in children {
            out.append(contentsOf: bytes[cursor..<child.range.start])
            renderSwitch(child, bytes: bytes, into: &out, branches: &branches)
            cursor = child.range.end
        }
        out.append(contentsOf: bytes[cursor..<range.end])
    }

    private static func renderSwitch(_ node: RegionNode, bytes: [UInt8], into out: inout [UInt8], branches: inout [Int: ByteRange]) {
        if let statement = node.mutants.first(where: \.isStatement) {
            precondition(node.mutants.count == 1, "a statement mutant must not share its range with other mutants")
            if statement.operator.replacesStatement {
                // Statement replacement: `if __xcmutate.isOn(ID) { mutated version } else { original statement }`
                out.append(contentsOf: Array("if \(switchCall(statement.id)) { ".utf8))
                let start = out.count
                out.append(contentsOf: Array(statement.mutatedExpression.utf8))
                branches[statement.id] = ByteRange(start: start, end: out.count)
                out.append(contentsOf: Array(" } else { ".utf8))
                render(range: node.range, children: node.children, bytes: bytes, into: &out, branches: &branches)
                out.append(contentsOf: Array(" }".utf8))
                return
            }
            if statement.operator.guardsCase {
                // Case removal: add ` where !__xcmutate.isOn(ID)` after each pattern (falls through to default)
                precondition(node.children.isEmpty, "a case pattern must not contain other mutants")
                var cursor = node.range.start
                for offset in (statement.guardOffsets ?? []).sorted() {
                    out.append(contentsOf: bytes[cursor..<offset])
                    out.append(contentsOf: Array(" where !\(switchCall(statement.id))".utf8))
                    cursor = offset
                }
                out.append(contentsOf: bytes[cursor..<node.range.end])
                return
            }
            // Statement removal / emptying the body: `if !__xcmutate.isOn(ID) { statement }` (no newline is added)
            out.append(contentsOf: Array("if !\(switchCall(statement.id)) { ".utf8))
            render(range: node.range, children: node.children, bytes: bytes, into: &out, branches: &branches)
            out.append(contentsOf: Array(" }".utf8))
            return
        }
        out.append(contentsOf: Array("(".utf8))
        for mutant in node.mutants {
            out.append(contentsOf: Array("\(switchCall(mutant.id)) ? (".utf8))
            let start = out.count
            out.append(contentsOf: Array(mutant.mutatedExpression.utf8))
            branches[mutant.id] = ByteRange(start: start, end: out.count)
            out.append(contentsOf: Array(") : ".utf8))
        }
        out.append(contentsOf: Array("(".utf8))
        render(range: node.range, children: node.children, bytes: bytes, into: &out, branches: &branches)
        out.append(contentsOf: Array("))".utf8))
    }
}

/// Mutants on the same range merged into one, arranged as a tree by range containment.
final class RegionNode {
    let range: ByteRange
    var mutants: [Mutant]
    var children: [RegionNode] = []

    init(range: ByteRange, mutants: [Mutant]) {
        self.range = range
        self.mutants = mutants
    }
}

struct RegionForest {
    var roots: [RegionNode] = []

    init(mutants: [Mutant]) {
        var groups: [ByteRange: [Mutant]] = [:]
        for m in mutants { groups[m.region, default: []].append(m) }
        let nodes = groups.keys.sorted().map { range in
            RegionNode(range: range, mutants: groups[range]!.sorted { $0.id < $1.id })
        }
        var stack: [RegionNode] = []
        for node in nodes {
            while let top = stack.last, !top.range.contains(node.range) {
                // Ranges are syntax tree nodes, so if they overlap, one always contains the other. Partial overlap is invalid.
                precondition(node.range.start >= top.range.end, "regions partially overlap: \(top.range) and \(node.range)")
                stack.removeLast()
            }
            if let top = stack.last {
                precondition(top.range.contains(node.range), "regions must nest or be disjoint")
                top.children.append(node)
            } else {
                roots.append(node)
            }
            stack.append(node)
        }
    }
}
