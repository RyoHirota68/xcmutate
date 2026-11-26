import Foundation
import MutatorCore

/// What a run is doing, for people and for programs.
///
/// - Phases. The run says which phase it is in (`begin`): the work copy, the build, the baseline, the mutants, the
///   final baseline. A phase ends when the next one begins, or with `end`.
/// - The heartbeat. When nothing has been printed for `interval` seconds, one line says which phase is still running,
///   for how long, and what can be seen of its progress (the files compiled, the tests that ended). A build of a
///   large app is about eight minutes without any other line.
/// - The progress file (`--progress-file`). One JSON object per line: the phases, every printed line, the heartbeats,
///   every mutant's result with the estimate of the time left, and the end of the run with its exit code.
public enum RunProgress {
    /// Version of the lines of the progress file. A field may be added within a version; a field is not removed or
    /// given another meaning without a new version.
    public static let formatVersion = 1

    /// Seconds without a printed line after which the heartbeat says that the phase is still running. A minute: often
    /// enough that a run does not look stopped, rarely enough that a run of an hour adds at most sixty lines.
    nonisolated(unsafe) public static var interval: TimeInterval = {
        if let text = ProcessInfo.processInfo.environment[ToolNaming.environmentPrefix + "HEARTBEAT_SECONDS"], let seconds = TimeInterval(text), seconds > 0 { return seconds }
        return 60
    }()

    private static let lock = NSLock()
    nonisolated(unsafe) private static var file: FileHandle?
    nonisolated(unsafe) private static var phase: (name: String, start: Date, hint: (() -> String?)?)?
    nonisolated(unsafe) private static var lastOutput = Date()
    nonisolated(unsafe) private static var timer: Thread?

    /// Starts writing the progress file at `url` (a new file; with `append`, after what is there).
    public static func open(_ url: URL, append: Bool) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !append || !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        lock.lock()
        file = handle
        lock.unlock()
    }

    /// The end of the run: its exit code, then the file is closed.
    public static func finish(exitCode: Int32, message: String? = nil) {
        end()
        var fields: [String: Any] = ["exitCode": Int(exitCode)]
        if let message { fields["message"] = message }
        write("runEnd", fields)
        lock.lock()
        try? file?.close()
        file = nil
        lock.unlock()
    }

    /// A phase begins (the one before ends). `hint` says, for the heartbeat, what can be seen of its progress.
    static func begin(_ name: String, hint: (() -> String?)? = nil) {
        end()
        lock.lock()
        phase = (name, Date(), hint)
        lock.unlock()
        write("phaseStart", ["phase": name])
        startTimer()
    }

    /// The current phase ends.
    static func end() {
        lock.lock()
        let ended = phase
        phase = nil
        lock.unlock()
        if let ended { write("phaseEnd", ["phase": ended.name, "seconds": round1(Date().timeIntervalSince(ended.start))]) }
    }

    /// A line was printed (`progress`).
    static func printed(_ message: String) {
        lock.lock()
        lastOutput = Date()
        lock.unlock()
        write("message", ["text": message])
    }

    /// The result of one mutant.
    static func mutant(index: Int, total: Int, mutant: Mutant, status: MutantStatus, seconds: Double, how: String, remaining: RemainingTime.Estimate) {
        write("mutant", ["index": index, "total": total, "id": mutant.id, "key": mutant.key, "file": mutant.file, "line": mutant.start.line,
                         "operator": mutant.operator.rawValue, "status": status.rawValue, "seconds": round1(seconds), "how": how,
                         "remainingSeconds": Int(remaining.seconds.rounded()), "remainingReliable": remaining.reliable])
    }

    static func write(_ event: String, _ fields: [String: Any]) {
        lock.lock()
        defer { lock.unlock() }
        guard let file else { return }
        var object = fields
        object["version"] = formatVersion
        object["event"] = event
        object["time"] = timestamp(Date())
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else { return }
        file.write(data + Data("\n".utf8))
    }

    /// The heartbeat line for a phase that has run for `elapsed` seconds.
    static func heartbeatLine(phase: String, elapsed: TimeInterval, hint: String?) -> String {
        "\(phase): still running after \(formatElapsed(elapsed))" + (hint.map { " (\($0))" } ?? "")
    }

    static func formatElapsed(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return total >= 60 ? "\(total / 60)m\(String(format: "%02d", total % 60))s" : "\(total)s"
    }

    private static func startTimer() {
        lock.lock()
        defer { lock.unlock() }
        guard timer == nil else { return }
        let thread = Thread {
            while true {
                Thread.sleep(forTimeInterval: min(5, interval / 4))
                beatIfQuiet()
            }
        }
        thread.name = "xcmutate heartbeat"
        timer = thread
        thread.start()
    }

    private static func beatIfQuiet() {
        lock.lock()
        guard let current = phase, Date().timeIntervalSince(lastOutput) >= interval else {
            lock.unlock()
            return
        }
        lastOutput = Date()
        lock.unlock()
        let elapsed = Date().timeIntervalSince(current.start)
        let hint = current.hint?()
        let line = heartbeatLine(phase: current.name, elapsed: elapsed, hint: hint)
        if !ProgressOutput.silent { FileHandle.standardError.write(Data("\(ToolInfo.name): \(line)\n".utf8)) }
        var fields: [String: Any] = ["phase": current.name, "seconds": round1(elapsed)]
        if let hint { fields["hint"] = hint }
        write("heartbeat", fields)
    }

    /// Tenths of a second, written as such (a `Double` would be written by JSONSerialization as 0.20000000000000001).
    private static func round1(_ value: Double) -> NSDecimalNumber { NSDecimalNumber(string: String(format: "%.1f", value)) }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    // MARK: What a log shows of a phase

    /// Source files that a build log shows as compiled so far (`SwiftCompile normal arm64 <file>`, `CompileC <object> <file>`).
    static func compiledFiles(inLog path: String) -> Int? {
        guard let text = tail(of: path, maxBytes: 64 << 20) else { return nil }
        var files: Set<Substring> = []
        for line in text.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("SwiftCompile ") || line.hasPrefix("CompileC ") {
                let words = line.split(separator: " ")
                // The absolute path of the source file (an escaped name such as `Compiling\ Cart.swift` is not counted)
                if let file = words.first(where: { $0.hasPrefix("/") && ($0.hasSuffix(".swift") || $0.hasSuffix(".m") || $0.hasSuffix(".mm") || $0.hasSuffix(".c") || $0.hasSuffix(".cpp")) }) {
                    files.insert(file)
                }
            }
        }
        return files.count
    }

    /// Tests that a log of `xcodebuild` shows as ended so far (XCTest and Swift Testing).
    static func endedTests(inLog path: String) -> Int? {
        guard let text = tail(of: path, maxBytes: 64 << 20) else { return nil }
        var count = 0
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.drop { $0 == "\u{200B}" }
            if line.hasPrefix("Test Case '"), line.contains("' passed (") || line.contains("' failed (") || line.contains("' skipped (") { count += 1 }
            if line.hasPrefix("\u{2714} Test ") || line.hasPrefix("\u{2718} Test "), !line.hasPrefix("\u{2714} Test run"), !line.hasPrefix("\u{2718} Test run"),
               line.contains(" passed after ") || line.contains(" failed after ") { count += 1 }
        }
        return count
    }

    private static func tail(of path: String, maxBytes: Int) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
