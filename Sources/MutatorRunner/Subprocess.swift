import Darwin
import Foundation

/// How a child process ended.
public struct ProcessOutcome: Sendable {
    /// Exit code. 128 + the signal number if it was stopped by a signal.
    public var status: Int32
    public var timedOut: Bool
    public var duration: TimeInterval
    /// With a `LogWatch`: seconds from the start of the process until one of the markers was in its log; nil if none was.
    public var firstMarkerAfter: TimeInterval?
    /// With a `LogWatch`: what stopped the process, if the watch did: `startup` (no test had started in time),
    /// `afterStart` (the time allowed after the first test), `stall` (one test did not end in time), or `crash`
    /// (`xcodebuild` said that it restarts the host after an unexpected exit).
    public var watchLimit: String?
    /// With `watchLimit == "crash"`: the test that had started last, as the log names it.
    public var crashedIn: String?
    /// With `watchLimit == "crash"` or `"stall"`: the tests that had started and not ended when the run was stopped.
    public var runningAtStop: [String] = []
    /// With `watchLimit == "crash"`: true if the log shows a failure of a test (an assertion that failed) between the
    /// start of that test and the unexpected exit.
    public var failedBeforeCrash: Bool?
    /// With a `LogWatch` that has a `stallLimit`: the longest time, once the first test had started, in which the log
    /// got no line of a test or suite starting or ending.
    public var longestQuiet: TimeInterval?
}

/// Watches the log of a child process for the first sign that the tests have started (a line that XCTest or Swift
/// Testing writes when a suite or a test starts), and applies two limits that the one limit of a whole run is too
/// coarse for: how long the process may take until then, and how long it may go on from then.
struct LogWatch: Sendable, Equatable {
    static let testStartMarkers = ["Test Suite '", "Test Case '", "\u{25C7} Test "]
    var markers = LogWatch.testStartMarkers
    /// Seconds allowed until a marker is seen; nil: only the limit of the whole run applies.
    var startupLimit: TimeInterval?
    /// Seconds allowed after a marker was seen; nil: only the limit of the whole run applies.
    var afterStart: TimeInterval?
    /// Seconds allowed without a new line of a test or suite that starts or ends, once the first was seen: the time
    /// one test may take. nil: no such limit.
    var stallLimit: TimeInterval?
    /// Further files in which the lines of tests can appear, besides the log of the process. With `--select-tests
    /// reach` the test process of the baseline writes its standard error, and with it every line that XCTest and
    /// Swift Testing print, into the trace file (so that the tests can be told from the switches they reach); the
    /// log of `xcodebuild` then has no line of a test from the first switch on.
    var alsoWatch: [String] = []
    /// Stop as soon as `xcodebuild` says that it restarts the host after an unexpected exit. Under `xcodebuild` a
    /// host that crashes is started again for the remaining tests, as often as it crashes; the first crash is
    /// what there is to learn.
    var stopAtCrash = false

    static let progressMarkers = testStartMarkers + ["\u{2714} Test ", "\u{2718} Test "]
    /// Lines that say that the tests of a run have ended (XCTest's outermost suite, Swift Testing's run). What comes
    /// after them is not a test: xcodebuild collecting results, the host going down. The limit for one test does
    /// not apply from there on; the limit of the run still does.
    static let endMarkers = ["Test Suite 'All tests' passed", "Test Suite 'All tests' failed", "Test Suite 'Selected tests' passed",
                             "Test Suite 'Selected tests' failed", "\u{2714} Test run with ", "\u{2718} Test run with "]
    static let crashMarker = "Restarting after unexpected exit, crash, or test timeout"

    /// The tests that had started and not ended in a log of `xcodebuild` (cut off where the host ended): `Class/method()`
    /// for XCTest, the name for Swift Testing. Swift Testing starts tests side by side, so there can be several; the
    /// one whose code ended the host is among them and the log does not say which.
    static func runningTests(in log: String) -> [String] {
        var running: [String] = []
        func name(xctest inner: Substring) -> String {
            let parts = inner.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { return String(inner) }
            let type = parts[0].split(separator: ".").last.map(String.init) ?? String(parts[0])
            return type + "/" + parts[1] + "()"
        }
        for line in log.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("Test Case '-[") {
                guard let close = line.range(of: "]' ") else { continue }
                let test = name(xctest: line[line.index(line.startIndex, offsetBy: "Test Case '-[".count)..<close.lowerBound])
                if line[close.upperBound...].hasPrefix("started") { running.append(test) } else { running.removeAll { $0 == test } }
            } else if line.hasPrefix("\u{25C7} Test "), line.hasSuffix(" started."), !line.hasPrefix("\u{25C7} Test run"), !line.hasPrefix("\u{25C7} Test case") {
                running.append(String(line.dropFirst("\u{25C7} Test ".count).dropLast(" started.".count)))
            } else if line.hasPrefix("\u{2714} Test ") || line.hasPrefix("\u{2718} Test ") {
                // "✔ Test name() passed after …", "✘ Test name() failed after …" (an issue that is recorded is not an end)
                let rest = line.dropFirst(7)
                for ending in [" passed after ", " failed after ", " skipped"] {
                    if let range = rest.range(of: ending) { running.removeAll { $0 == String(rest[..<range.lowerBound]) } }
                }
            }
        }
        return running
    }

    /// The line in which the test host said that it terminates because of an uncaught exception, if the host itself
    /// wrote it and no test started or ended after it; nil otherwise.
    ///
    /// Only a line with the prefix of NSLog / os_log is taken (`2026-11-26 13:46:19.126 App[50059:234069962] *** Terminating
    /// app due to uncaught exception …`), and only when the name is one of `hosts` and the process ID is that of the
    /// first such line of the log: the host starts first. A process that the tests start (a Swift Testing exit test,
    /// a `Process`) can write to the same log, with another process ID; lines without the prefix (`libc++abi:
    /// terminating`, Swift's `Fatal error:`) do not say which process wrote them, and are not taken. A test that
    /// started or ended after the line shows that the host went on.
    static func terminationLine(in log: String, hosts: Set<String>) -> String? {
        var hostID: [String: Substring] = [:]
        var found: String?
        for line in log.split(whereSeparator: \.isNewline) {
            // Swift Testing puts a zero-width space before some of its lines
            let raw = line.drop { $0 == "\u{200B}" }
            if let match = raw.firstMatch(of: /^\d{4}-\d{2}-\d{2} [0-9:.]+(?:[+-]\d{4})? ([^\[\] ]+)\[(\d+):[0-9a-fx]+\] (.*)$/) {
                let name = String(match.1)
                guard hosts.contains(name) else { continue }
                let pid = hostID[name] ?? match.2
                hostID[name] = pid
                if match.2 == pid, match.3.hasPrefix("*** Terminating app due to uncaught exception") {
                    if found == nil { found = String(raw.prefix(300)) }
                }
                continue
            }
            let event = raw.hasPrefix("Test Case '") || raw.hasPrefix("Test Suite '") || raw.hasPrefix("\u{2714} Test ") || raw.hasPrefix("\u{2718} Test ")
                || (raw.hasPrefix("\u{25C7} Test ") && raw.hasSuffix(" started."))
            if event { found = nil }
        }
        return found
    }

    /// Whether the log shows a failed assertion of `test` (a name as `runningTests` gives it): XCTest writes
    /// `<file>:<line>: error: -[Module.Class method] : …`, Swift Testing `✘ Test name() recorded an issue …`.
    static func failed(_ test: String, in log: String) -> Bool {
        let parts = test.dropLast(test.hasSuffix("()") ? 2 : 0).split(separator: "/", maxSplits: 1)
        return log.split(whereSeparator: \.isNewline).contains { line in
            if line.hasPrefix("\u{2718} Test \(test) recorded an issue") { return true }
            guard parts.count == 2, let range = line.range(of: ": error: -[") else { return false }
            let rest = line[range.upperBound...]
            return rest.contains(".\(parts[0]) \(parts[1])]") || rest.hasPrefix("\(parts[0]) \(parts[1])]")
        }
    }

    /// Reads what was appended to a file since the last call and says whether a marker is in it.
    final class Reader {
        private let path: String
        private let markers: [Data]
        private var offset: UInt64 = 0
        private var carry = Data()
        /// Readers of the further files (`LogWatch.alsoWatch`): a marker in any of the files counts.
        private var others: [Reader] = []

        init(path: String, markers: [String], also: [String] = []) {
            self.path = path
            self.markers = markers.map { Data($0.utf8) }
            others = also.map { Reader(path: $0, markers: markers) }
        }

        func sawMarker() -> Bool {
            // Every file is read (no short circuit: each reader has to keep up with its file)
            let elsewhere = others.map { $0.sawMarker() }.contains(true)
            return sawMarkerHere() || elsewhere
        }

        /// As `lastMarkerIsEnding`, over all the files: the answer of the file that had something new last.
        func lastMarkerIsEndingAnywhere(_ endings: [String]) -> Bool? {
            var answer = lastMarkerIsEnding(endings)
            for other in others { if let theirs = other.lastMarkerIsEnding(endings) { answer = theirs } }
            return answer
        }

        private func sawMarkerHere() -> Bool {
            guard let handle = FileHandle(forReadingAtPath: path) else { return false }
            defer { try? handle.close() }
            guard (try? handle.seek(toOffset: offset)) != nil, let new = try? handle.readToEnd(), !new.isEmpty else { return false }
            offset += UInt64(new.count)
            // A marker can lie across two reads: the end of the read before is looked at again, but only as much of
            // it as a marker that ends in the new bytes needs (a marker that was seen is not seen twice)
            let longest = markers.map(\.count).max() ?? 1
            let text = carry.suffix(max(longest - 1, 0)) + new
            carry = Data(text.suffix(max(longest - 1, 0)))
            return markers.contains { text.range(of: $0) != nil }
        }

        /// Reads what was appended since the last call. nil: none of the markers is in it. Otherwise whether the
        /// marker that comes last in it is one of `endings` (the others are lines of tests that start or end).
        func lastMarkerIsEnding(_ endings: [String]) -> Bool? {
            guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
            defer { try? handle.close() }
            guard (try? handle.seek(toOffset: offset)) != nil, let new = try? handle.readToEnd(), !new.isEmpty else { return nil }
            offset += UInt64(new.count)
            let longest = max(markers.map(\.count).max() ?? 1, endings.map(\.utf8.count).max() ?? 1)
            let text = carry.suffix(max(longest - 1, 0)) + new
            carry = Data(text.suffix(max(longest - 1, 0)))
            func last(_ candidates: [Data]) -> Int? {
                candidates.compactMap { text.range(of: $0, options: .backwards)?.lowerBound }.max()
            }
            let ending = last(endings.map { Data($0.utf8) })
            let other = last(markers)
            if ending == nil, other == nil { return nil }
            // An ending line of Swift Testing begins like a line of a test: at the same place the ending wins
            return (ending ?? -1) >= (other ?? -1)
        }
    }
}

/// Process groups of the running child processes. Stopped together on an interrupt (Ctrl-C).
final class ChildRegistry: @unchecked Sendable {
    static let shared = ChildRegistry()
    private let lock = NSLock()
    private var groups: Set<pid_t> = []

    func add(_ pgid: pid_t) { lock.lock(); groups.insert(pgid); lock.unlock() }
    func remove(_ pgid: pid_t) { lock.lock(); groups.remove(pgid); lock.unlock() }

    /// Sends SIGTERM to all groups, waits a little, then sends SIGKILL.
    func terminateAll() {
        lock.lock()
        let current = groups
        lock.unlock()
        for pgid in current { kill(-pgid, SIGTERM) }
        if current.isEmpty { return }
        usleep(2_000_000)
        for pgid in current { kill(-pgid, SIGKILL) }
    }
}

public enum SubprocessError: Error, CustomStringConvertible {
    case spawnFailed(String, Int32)

    public var description: String {
        switch self {
        case let .spawnFailed(command, code): "failed to start \(command): \(String(cString: strerror(code)))"
        }
    }
}

/// Launches a child process in its own process group (so that the whole group can be stopped on a timeout or an interrupt).
enum Subprocess {
    /// What happens to a child that ran out of time or that an interrupt stops.
    enum Stop: Sendable, Equatable {
        /// SIGTERM, then SIGKILL after this many seconds (a child that writes something on its way out).
        case graceful(seconds: Double)
        /// SIGKILL at once (nothing the child would still write is needed).
        case immediate
    }

    /// The attributes every child is started with: a process group of its own, no blocked signals, and the default
    /// action for the signals that this tool ignores or handles itself. Without the second, a child inherits "ignore SIGTERM"
    /// from the tool (`InterruptHandler`) and can only be stopped with SIGKILL, ten seconds later.
    private static func withSpawnAttributes<T>(_ body: (inout posix_spawnattr_t?) throws -> T) rethrows -> T {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attributes, 0)
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for signal in [SIGINT, SIGTERM, SIGHUP] { sigaddset(&defaults, signal) }
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        // And no signal blocked: a child also inherits the signal mask of the thread that starts it, and a thread of
        // a concurrency pool may have signals blocked (then SIGTERM would stay pending in the child for ever)
        var mask = sigset_t()
        sigemptyset(&mask)
        posix_spawnattr_setsigmask(&attributes, &mask)
        return try body(&attributes)
    }

    private static func start(_ arguments: [String], cwd: String?, environment: [String: String], logPath: String) throws -> pid_t {
        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        posix_spawn_file_actions_addopen(&fileActions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&fileActions, 1, logPath, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        posix_spawn_file_actions_adddup2(&fileActions, 1, 2)
        if let cwd { posix_spawn_file_actions_addchdir_np(&fileActions, cwd) }

        var env = ProcessInfo.processInfo.environment
        for (key, value) in environment { env[key] = value }
        let argv = arguments.map { strdup($0) } + [nil]
        let envp = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        let spawnStatus = withSpawnAttributes { attributes in
            posix_spawnp(&pid, arguments[0], &fileActions, &attributes, argv, envp)
        }
        guard spawnStatus == 0 else { throw SubprocessError.spawnFailed(arguments[0], spawnStatus) }
        ChildRegistry.shared.add(pid)
        return pid
    }

    /// - Parameters:
    ///   - logPath: File to which standard output and standard error are written.
    ///   - timeout: When exceeded, the process group is stopped as `stop` says.
    ///   - stop: How a child that timed out, or that an interrupt (Ctrl-C) reaches, is stopped.
    ///   - ignoresInterrupt: The command is part of the clean-up after an interrupt (deleting a worker simulator,
    ///     stopping a test host): it runs although the interrupt flag is set.
    static func run(
        _ arguments: [String], cwd: String? = nil, environment: [String: String] = [:],
        logPath: String, timeout: TimeInterval? = nil, stop: Stop = .graceful(seconds: 5), ignoresInterrupt: Bool = false,
        watch: LogWatch? = nil
    ) throws -> ProcessOutcome {
        let pid = try start(arguments, cwd: cwd, environment: environment, logPath: logPath)
        defer { ChildRegistry.shared.remove(pid) }

        let start = Date()
        var timedOut = false
        var termSentAt: Date?
        var interruptSent = false
        var status: Int32 = 0
        let reader = watch.map { LogWatch.Reader(path: logPath, markers: $0.markers, also: $0.alsoWatch) }
        let progress = watch.flatMap { $0.stallLimit == nil ? nil : LogWatch.Reader(path: logPath, markers: LogWatch.progressMarkers, also: $0.alsoWatch) }
        let crashes = watch.flatMap { $0.stopAtCrash ? LogWatch.Reader(path: logPath, markers: [LogWatch.crashMarker]) : nil }

        /// The tests of the run have ended (as far as the log says): no test can be stuck any more.
        var testsEnded = false
        var firstMarker: TimeInterval?
        var watchLimit: String?
        var lastLook = 0.0
        var lastProgress = 0.0
        var lastProgressLook = 0.0
        var longestQuiet = 0.0
        func stopGroup() {
            switch stop {
            case .immediate:
                kill(-pid, SIGKILL)
            case .graceful:
                termSentAt = Date()
                kill(-pid, SIGTERM)
            }
        }
        while true {
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid { break }
            if result == -1, errno != EINTR { break }
            let elapsed = Date().timeIntervalSince(start)
            if let timeout, !timedOut, elapsed > timeout {
                timedOut = true
                stopGroup()
            }
            if let watch, let reader, !timedOut {
                if firstMarker == nil, elapsed - lastLook >= 0.25 {
                    lastLook = elapsed
                    if reader.sawMarker() { firstMarker = elapsed }
                }
                if firstMarker == nil, let limit = watch.startupLimit, elapsed > limit {
                    // One more look: the marker may have been written since the last one
                    if reader.sawMarker() {
                        firstMarker = elapsed
                    } else {
                        timedOut = true
                        watchLimit = "startup"
                        stopGroup()
                    }
                }
                if let seen = firstMarker, let limit = watch.afterStart, elapsed > seen + limit, !timedOut {
                    timedOut = true
                    watchLimit = "afterStart"
                    stopGroup()
                }
                if elapsed - lastProgressLook >= 0.25, !timedOut {
                    lastProgressLook = elapsed
                    if let crashes, crashes.sawMarker() {
                        timedOut = true
                        watchLimit = "crash"
                        stopGroup()
                    } else if let progress, let ended = progress.lastMarkerIsEndingAnywhere(LogWatch.endMarkers) {
                        if let seen = firstMarker, !testsEnded { longestQuiet = max(longestQuiet, elapsed - max(seen, lastProgress)) }
                        lastProgress = elapsed
                        // The last line of what is new decides: the end of the tests, or a test (also one that starts
                        // after an end: Swift Testing's run comes after XCTest's suites)
                        testsEnded = ended
                    }
                }
                if let seen = firstMarker, let limit = watch.stallLimit, let progress, !testsEnded, elapsed > max(seen, lastProgress) + limit, !timedOut {
                    // One more look before a test is taken to be stuck
                    if let ended = progress.lastMarkerIsEndingAnywhere(LogWatch.endMarkers) {
                        lastProgress = elapsed
                        testsEnded = ended
                    } else {
                        timedOut = true
                        watchLimit = "stall"
                        stopGroup()
                    }
                }
            }
            // Interrupt (Ctrl-C): stop the child process group (counted separately from a timeout)
            if !ignoresInterrupt, InterruptState.isInterrupted, !interruptSent {
                interruptSent = true
                stopGroup()
            }
            if let sent = termSentAt, case let .graceful(seconds) = stop, Date().timeIntervalSince(sent) > seconds {
                kill(-pid, SIGKILL)
                termSentAt = nil
            }
            usleep(20_000)
        }
        // Also stop the descendants remaining in the group
        if timedOut || interruptSent { kill(-pid, SIGKILL) }
        let exitCode: Int32 = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        if let reader, firstMarker == nil, !timedOut, reader.sawMarker() { firstMarker = Date().timeIntervalSince(start) }
        var crashedIn: String?
        var failedBeforeCrash: Bool?
        var running: [String] = []
        if watchLimit == "crash" || watchLimit == "stall" {
            // The tests that were running where the log stops. For a crash the log is cut where xcodebuild says that
            // it restarts the host (by the time the log is read, tests of the restarted host may have started). Only
            // a single test is named: a wrong name is worse than none
            var text = (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? ""
            if watchLimit == "crash", let marker = text.range(of: LogWatch.crashMarker) { text = String(text[..<marker.lowerBound]) }
            running = LogWatch.runningTests(in: text)
            if running.count == 1 {
                crashedIn = running[0]
                if watchLimit == "crash" { failedBeforeCrash = LogWatch.failed(running[0], in: text) }
            }
        }
        return ProcessOutcome(status: exitCode, timedOut: timedOut, duration: Date().timeIntervalSince(start), firstMarkerAfter: firstMarker, watchLimit: watchLimit,
                              crashedIn: crashedIn, runningAtStop: running, failedBeforeCrash: failedBeforeCrash, longestQuiet: progress != nil && firstMarker != nil ? longestQuiet : nil)
    }

    /// Starts a child process in its own process group and returns without waiting. The caller polls `RunningProcess`.
    static func spawn(_ arguments: [String], cwd: String? = nil, environment: [String: String] = [:], logPath: String) throws -> RunningProcess {
        RunningProcess(pid: try start(arguments, cwd: cwd, environment: environment, logPath: logPath))
    }

    /// Returns the output as a string (for short commands).
    static func capture(_ arguments: [String], cwd: String? = nil, environment: [String: String] = [:], timeout: TimeInterval? = 120,
                        ignoresInterrupt: Bool = false) throws -> (status: Int32, output: String) {
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("\(ToolInfo.name)-\(UUID().uuidString).log").path
        defer { try? FileManager.default.removeItem(atPath: log) }
        let outcome = try run(arguments, cwd: cwd, environment: environment, logPath: log, timeout: timeout, ignoresInterrupt: ignoresInterrupt)
        let output = (try? String(contentsOfFile: log, encoding: .utf8)) ?? ""
        return (outcome.status, output)
    }
}

/// A child process started with `Subprocess.spawn`.
final class RunningProcess {
    let pid: pid_t
    let start = Date()
    private var exitStatus: Int32?

    init(pid: pid_t) { self.pid = pid }

    /// The exit code if the process has ended (128 + the signal number if it was stopped by a signal), else nil.
    func poll() -> Int32? {
        if let exitStatus { return exitStatus }
        var status: Int32 = 0
        let result = waitpid(pid, &status, WNOHANG)
        guard result == pid || (result == -1 && errno != EINTR) else { return nil }
        let code: Int32 = result == pid ? ((status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)) : -1
        exitStatus = code
        ChildRegistry.shared.remove(pid)
        return code
    }

    /// Stops the whole process group at once (SIGKILL) and reaps the process. Used when nothing the process would still
    /// write is needed.
    func kill() {
        guard poll() == nil else { return }
        Darwin.kill(-pid, SIGKILL)
        for _ in 0..<200 {
            if poll() != nil { return }
            usleep(10_000)
        }
    }
}

/// Whether an interrupt (Ctrl-C, SIGTERM) has been received.
public enum InterruptState {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var flag = false

    public static var isInterrupted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }

    static func set() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let was = flag
        flag = true
        return was
    }

    nonisolated(unsafe) private static var limitFlag = false

    /// The run was cut short by `--time-limit`, not by a signal.
    public static var timeLimitReached: Bool {
        lock.lock()
        defer { lock.unlock() }
        return limitFlag
    }

    nonisolated(unsafe) private static var gateReason: String?

    /// `--stop-when-gate-decided`: why the gate's result is decided ("passes: …", "fails: …"); nil if it was not.
    public static var gateDecision: String? {
        lock.lock()
        defer { lock.unlock() }
        return gateReason
    }

    /// The gate's result can no longer change: the run is cut short as by the time limit. False if the run was being
    /// interrupted already.
    static func decideGate(_ reason: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !flag else { return false }
        flag = true
        gateReason = reason
        return true
    }

    /// `--time-limit`: the time is up. The run is cut short as by an interrupt (the child processes are stopped,
    /// the report of the results so far is written). False if the run was being interrupted already.
    static func reachTimeLimit() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !flag else { return false }
        flag = true
        limitFlag = true
        return true
    }
}

/// `--time-limit`: cuts the run short when the time is up, unless it has ended before (`cancel`).
public final class TimeLimit: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    init(seconds: Double, describedAs text: String) {
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [self] in
            lock.lock()
            let stop = !cancelled
            lock.unlock()
            guard stop, InterruptState.reachTimeLimit() else { return }
            FileHandle.standardError.write(Data("\n\(ToolInfo.name): the time limit (--time-limit \(text)) is reached; stopping child processes and writing the results so far...\n".utf8))
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    /// `90`, `90s`, `45m`, `2h`, `1h30m`: seconds. nil if the text is not a duration or is not positive.
    public static func parse(_ text: String) -> Double? {
        var total = 0.0
        var number = ""
        var units = 0
        for character in text {
            if character.isNumber || character == "." {
                number.append(character)
                continue
            }
            guard let value = Double(number), let factor = ["s": 1.0, "m": 60.0, "h": 3600.0][String(character)] else { return nil }
            total += value * factor
            number = ""
            units += 1
        }
        if !number.isEmpty {
            // A bare number is seconds; after a unit it would be ambiguous (`1h30`)
            guard units == 0, let value = Double(number) else { return nil }
            total += value
        }
        return total > 0 ? total : nil
    }
}

/// On Ctrl-C (SIGINT), SIGTERM or SIGHUP (the terminal was closed), stops the running child processes, writes the report with the results so far and exits
/// (`RunSession` checks `InterruptState` and cuts the run short). On a second signal, exits immediately.
/// Since this approach never rewrites the user's working tree, there is nothing to restore.
public enum InterruptHandler {
    nonisolated(unsafe) private static var sources: [DispatchSourceSignal] = []

    public static func install() {
        // SIGHUP too: without it the tool ends when its terminal closes, while xcodebuild and the test host, which are
        // in process groups of their own, run on (a mutant that loops forever, with nobody left to time it out) and
        // the worker simulators stay booted
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            source.setEventHandler {
                if InterruptState.set() {
                    FileHandle.standardError.write(Data("\n\(ToolInfo.name): interrupted again; exiting now\n".utf8))
                    ChildRegistry.shared.terminateAll()
                    exit(130)
                }
                FileHandle.standardError.write(Data("\n\(ToolInfo.name): interrupted; stopping child processes and writing the results so far (interrupt again to exit immediately)...\n".utf8))
            }
            source.resume()
            sources.append(source)
        }
    }
}

/// Keeps the Mac from sleeping during a long run (sleeping can cause a false Timeout through the wall-clock timeout).
/// Launches `caffeinate -i -w <own PID>` as a child process. caffeinate ends when this process ends, so no cleanup is needed.
public enum SleepPrevention {
    public static func start() {
        var pid: pid_t = 0
        let arguments = ["/usr/bin/caffeinate", "-i", "-w", String(getpid())]
        let argv = arguments.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        for fd in [Int32(0), 1, 2] { posix_spawn_file_actions_addopen(&fileActions, fd, "/dev/null", O_RDWR, 0) }
        _ = posix_spawn(&pid, arguments[0], &fileActions, nil, argv, environ)
    }
}
