import MutatorCore

/// Source of the driver that runs several mutants in one test process (`--shared-process`).
///
/// The tool compiles this file into a test bundle of its own and points a copy of the `.xctestrun` file at it, so
/// the project under test is not changed in any way: no file is added to its test target and nothing is appended
/// to its sources. `xcodebuild` launches the test host as usual and runs the one test of this bundle. That test
/// loads the project's own test bundle into the same process and then, for each mutant of the plan, switches the
/// mutant on through the shared region (see `Instrumenter.sharedEnvironmentVariable`) and runs the project's tests:
/// XCTest classes through the public `XCTestSuite` / `XCTestCase` API, Swift Testing through its documented
/// ABI entry point (`swt_abiv0_getEntryPoint`, looked up at run time so that the bundle does not link Testing).
///
/// What it writes to `events.log` (one line per event, fields separated by a space, test names by a tab):
///
///     HELLO <pid> <1 if Swift Testing is present, else 0>
///     CONTROL <1|2> <ok|fail|error> <tests> <seconds>[\t<failed test>…]
///     CLASSES                                               (classes.txt is written: which switches the two runs evaluated, and how)
///     READY                                                 (plan gate `known`: no runs without mutants at the start)
///     SKIP <id> <launch|uneven|unreached>
///     PRE <id> <ok|fail|error> <tests> <seconds>            (plan gate `known`: the first mutant's tests without mutants, before it)
///     BEGIN <id> <1|0>                                      (1: the same tests have just passed without mutants in this process)
///     END <id> <pass|fail|error> <activations> <tests> <seconds>[\t<failed test>…]   (error: incomplete, or another number of tests)
///     CHECK <id> <ok|fail|error> <tests> <seconds>          (after an END that is not pass: the same tests without mutants)
///     DIRECT <id>                                           (the failing run came directly after a passing run without mutants)
///     AGAIN <id> <pass|fail|error> <activations> <tests> <seconds>[\t<failed test>…]   (otherwise: the mutant once more, after CHECK)
///     CHECK2 <id> <ok|fail|error> <tests> <seconds>         (after an AGAIN that is not pass)
///     SETTLED <id>                                          (the driver is done with this mutant)
///     SINGLE <pass|fail|error> <tests> <seconds>[\t<failed test>…]   (plan mode `single`: one run of the tests, nothing else)
///     STOP <reason>
///     DONE
///
/// Two ways into the driver:
/// - `xcodebuild`, or the `xctest` agent started by the tool itself, runs the one XCTest test of the bundle;
/// - for a test host that is an app started by the tool itself (no `xcodebuild`), the same source is compiled into a
///   dynamic library with `xcmutateDirectStart` as its initializer; the library is inserted into the app with
///   `DYLD_INSERT_LIBRARIES` and starts the session from the main run loop once the app has finished launching,
///   which is when XCTest would start the tests.
///
/// In plan mode `single` the driver runs the selected tests exactly once and reports the result. The tool uses it
/// with the mutant switched on through the environment from the start of the process (as in a run under
/// `xcodebuild`), to confirm in a new process a mutant whose tests passed in a shared process.
///
/// The idea of repeating the suite inside the test process is from `debugholic/litmus` (MIT License; `Batch.swift`).
/// The implementation is separate: litmus appends its driver to a file of the test target and calls an SPI of
/// Swift Testing; this driver is a bundle of its own and uses the ABI entry point.
enum SharedProcessDriverSource {
    static let className = "XCMutateSharedProcess"
    static let testName = "testRunMutants"
    static let sessionEnvironmentVariable = ToolNaming.environmentPrefix + "SESSION"
    /// Initializer of the dynamic-library form of the driver (`-init` of the linker).
    static let directEntryPoint = "xcmutateDirectStart"

    static let source = #"""
    import Foundation
    import XCTest

    final class XCMutateSharedProcess: XCTestCase {
        func testRunMutants() {
            guard let directory = ProcessInfo.processInfo.environment["XCMUTATE_SESSION"] else { return }
            XCMutateSessionRunner(directory: directory)?.run()
        }
    }

    private struct XCMutatePlan: Decodable {
        struct Entry: Decodable {
            var id: Int
            /// Tests to run for this mutant (`Class`, `Class/method`); nil: the whole selection.
            var only: [String]?
            /// Number of tests that a passing run of `only` executes; nil: the number of the control run.
            var tests: Int?
        }
        var bundlePath: String
        var bundleName: String
        var sharedPath: String
        var moduleName: String
        var only: [String]
        var skip: [String]
        var mutants: [Entry]
        /// "single": run the tests of `single` once and report (the mutant, if any, is on through the environment).
        var mode: String?
        var single: Entry?
        /// "auto" (nil): a failing run that did not come directly after a passing run of the same tests without
        /// mutants is repeated after such a run. "all": every failing run is. "none": none is.
        var confirm: String?
        /// "known": an earlier process of this unit on this destination has made the two runs without mutants. This
        /// process does not repeat them; the tool sends only mutants that those runs found to be evaluated equally
        /// often. Before the first mutant, its tests are run once without mutants.
        var gate: String?
        /// Plan gate `known`: number of tests in a run of the whole selection.
        var controlTests: Int?
        /// Plan mode `single`: stop after the first test that fails (the tool takes only a pass from such a run).
        var stopAtFirstFailure: Bool?
    }

    /// Entry point of the dynamic-library form (inserted into an app that the tool launched without xcodebuild).
    @_cdecl("xcmutateDirectStart")
    public func xcmutateDirectStart() {
        guard let directory = ProcessInfo.processInfo.environment["XCMUTATE_SESSION"] else { return }
        // XCTest starts the tests of an app-hosted bundle when the app has finished launching; so does this.
        // The session must not run inside a block of the main dispatch queue: that queue would be blocked for the
        // tests, and a test that waits for work dispatched to it would never see it.
        let started = XCMutateBox(false)
        for name in ["UIApplicationDidFinishLaunchingNotification", "NSApplicationDidFinishLaunchingNotification"] {
            _ = NotificationCenter.default.addObserver(forName: Notification.Name(name), object: nil, queue: nil) { _ in
                var first = false
                started.update { if !$0 { $0 = true; first = true } }
                guard first else { return }
                RunLoop.main.perform {
                    XCMutateSessionRunner(directory: directory)?.run()
                }
            }
        }
    }

    private final class XCMutateBox<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: T
        init(_ value: T) { self.value = value }
        func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
        func update(_ change: (inout T) -> Void) { lock.lock(); change(&value); lock.unlock() }
    }

    private struct XCMutatePass {
        var completed = true
        var tests = 0
        var failed: [String] = []
        var seconds = 0.0
        var status: String { !completed ? "error" : (failed.isEmpty ? "pass" : "fail") }
    }

    private final class XCMutateSessionRunner {
        private let directory: String
        private let plan: XCMutatePlan
        private let events: FileHandle
        private var cells: UnsafeMutablePointer<Int>!
        private var counters = 0
        private var bundlePath = ""
        private var bundleSpellings: [String] = []
        private typealias Entry = @convention(thin) @Sendable (UnsafeRawBufferPointer?, @escaping @Sendable (UnsafeRawBufferPointer) -> Void) async throws -> Bool
        private var swiftTesting: Entry?
        private var controlTests = 0
        private static var principalMade = false
        /// While set: every test that starts is written to `tests.log`. On during the runs without mutants at the
        /// start of a process, so that the test in which a process died or stopped can be named.
        private let testLog = XCMutateBox<FileHandle?>(nil)

        init?(directory: String) {
            self.directory = directory
            let eventsPath = directory + "/events.log"
            guard let data = FileManager.default.contents(atPath: directory + "/plan.json"),
                  let plan = try? JSONDecoder().decode(XCMutatePlan.self, from: data) else { return nil }
            self.plan = plan
            // A second launch of the same session (xcodebuild relaunches the host after a crash) must not run anything again.
            if let size = (try? FileManager.default.attributesOfItem(atPath: eventsPath))?[.size] as? Int, size > 0 {
                if let handle = FileHandle(forWritingAtPath: eventsPath) {
                    handle.seekToEndOfFile()
                    handle.write(Data("RELAUNCH\n".utf8))
                }
                return nil
            }
            FileManager.default.createFile(atPath: eventsPath, contents: nil)
            guard let handle = FileHandle(forWritingAtPath: eventsPath) else { return nil }
            events = handle
        }

        private func emit(_ line: String) {
            events.seekToEndOfFile()
            events.write(Data((line + "\n").utf8))
        }

        private func logTests(_ on: Bool) {
            if on {
                let path = directory + "/tests.log"
                if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
                let handle = FileHandle(forWritingAtPath: path)
                handle?.seekToEndOfFile()
                testLog.update { $0 = handle }
            } else {
                testLog.update { $0 = nil }
            }
        }

        private func noteTestStart(_ name: String) {
            testLog.update { $0?.write(Data((name + "\n").utf8)) }
        }

        func run() {
            guard prepare() else {
                emit("DONE")
                return
            }
            if plan.mode == "single" {
                let entry = plan.single
                logTests(true)
                let result = pass(only: entry?.only)
                emit("SINGLE \(result.status) \(result.tests) \(result.seconds)" + names(result.failed))
                return finish(nil)
            }
            let launch = snapshot()
            let gateKnown = plan.gate == "known"
            var afterFirst = launch
            var afterSecond = launch
            // The tests that have just passed without mutants, with no other run since ("*": the whole selection)
            var cleanSelection: String?
            if gateKnown {
                controlTests = plan.controlTests ?? 0
                emit("READY")
            } else {
                logTests(true)
                let first = pass(only: nil)
                emit("CONTROL 1 \(first.status == "pass" ? "ok" : first.status) \(first.tests) \(first.seconds)" + names(first.failed))
                guard first.status == "pass" else { return finish("control") }
                afterFirst = snapshot()
                let second = pass(only: nil)
                let secondOK = second.status == "pass" && second.tests == first.tests
                emit("CONTROL 2 \(secondOK ? "ok" : (second.status == "pass" ? "fail" : second.status)) \(second.tests) \(second.seconds)" + names(second.failed))
                guard secondOK else { return finish("control") }
                afterSecond = snapshot()
                logTests(false)
                controlTests = first.tests
                cleanSelection = "*"
                writeClasses(launch: launch, afterFirst: afterFirst, afterSecond: afterSecond)
            }
            var prechecked = false

            for entry in plan.mutants {
                let id = entry.id
                // A switch that was evaluated before the tests started (app launch), or more or less often in the first run
                // than in the second (lazy statics, caches, anything done once per process), cannot be judged in a process
                // that has already run the tests: it goes back to a process of its own.
                if id < 0 || id >= counters {
                    emit("SKIP \(id) unreached")
                    continue
                }
                if launch[id] != 0 {
                    emit("SKIP \(id) launch")
                    continue
                }
                if !gateKnown {
                    let inFirst = afterFirst[id] - launch[id]
                    let inSecond = afterSecond[id] - afterFirst[id]
                    if inFirst != inSecond {
                        emit("SKIP \(id) uneven")
                        continue
                    }
                    if inSecond == 0 {
                        emit("SKIP \(id) unreached")
                        continue
                    }
                }
                let key = entry.only?.joined(separator: "\n") ?? "*"
                if gateKnown, !prechecked {
                    // Nothing has run in this process yet. The first mutant's tests must pass here without mutants
                    // before anything is judged: that shows that the process works and that the destination holds
                    // nothing that fails these tests by itself, and it makes the first mutant's run one that
                    // comes directly after a passing run of the same tests.
                    prechecked = true
                    guard check("PRE", id, entry) else { return finish("precheck") }
                    cleanSelection = key
                }
                // The whole selection has just passed: so have the tests of any mutant
                let cleanAtBegin = cleanSelection == key || cleanSelection == "*"
                emit("BEGIN \(id) \(cleanAtBegin ? 1 : 0)")
                let result = run(entry)
                emit("END \(id) \(result.status) \(result.activations) \(result.tests) \(result.seconds)" + names(result.failed))
                if result.status == "pass" {
                    // The run changed nothing that a test can see, as far as is known, but it was not a run without mutants
                    cleanSelection = nil
                    emit("SETTLED \(id)")
                    continue
                }
                // The failing run counts as it is only when it came directly after the same tests had passed without
                // mutants: then nothing but the mutant stands between a pass and the failure.
                let direct = cleanAtBegin
                // After a run that did not pass, the same tests must pass again without the mutant. If they do not, the failing run
                // (or an earlier one) left the process in a state that fails tests on its own, and nothing more is judged here.
                guard check("CHECK", id, entry) else { return finish("dirty") }
                cleanSelection = key
                if result.status == "fail", plan.confirm != "none" {
                    if direct, plan.confirm != "all" {
                        emit("DIRECT \(id)")
                    } else {
                        // An earlier mutant may have left state that failed these tests (and the failing run may have
                        // cleared it). Now the tests have just passed without mutants: the mutant must fail them again.
                        let again = run(entry)
                        emit("AGAIN \(id) \(again.status) \(again.activations) \(again.tests) \(again.seconds)" + names(again.failed))
                        if again.status == "pass" {
                            cleanSelection = nil
                        } else {
                            guard check("CHECK2", id, entry) else { return finish("dirty") }
                        }
                    }
                }
                emit("SETTLED \(id)")
            }
            finish(nil)
        }

        /// One run of the mutant's tests with the mutant on.
        private func run(_ entry: XCMutatePlan.Entry) -> (status: String, activations: Int, tests: Int, seconds: Double, failed: [String]) {
            cells[1] = 0
            cells[0] = entry.id
            let result = pass(only: entry.only)
            cells[0] = -1
            let activations = cells[1]
            var status = result.status
            // A run counts only if it ran as many tests as a run without mutants does.
            if status != "error", result.tests != (entry.only == nil ? controlTests : (entry.tests ?? -1)) { status = "error" }
            return (status, activations, result.tests, result.seconds, result.failed)
        }

        /// The mutant's tests once without mutants; true if they pass, as many as expected.
        private func check(_ label: String, _ id: Int, _ entry: XCMutatePlan.Entry) -> Bool {
            let result = pass(only: entry.only)
            var status = result.status
            if status == "pass", result.tests != (entry.only == nil ? controlTests : (entry.tests ?? -1)) { status = "error" }
            emit("\(label) \(id) \(status == "pass" ? "ok" : status) \(result.tests) \(result.seconds)")
            return status == "pass"
        }

        private func finish(_ reason: String?) {
            if let reason { emit("STOP \(reason)") }
            emit("DONE")
            // The tool stops this process when it reads DONE. Returning would let XCTest report a state it does not expect
            // (tests were run inside a test), so wait here; give up after a while in case the tool is gone.
            Thread.sleep(forTimeInterval: 60)
        }

        private func names(_ list: [String]) -> String {
            list.isEmpty ? "" : "\t" + list.prefix(20).map { $0.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") }.joined(separator: "\t")
        }

        private func snapshot() -> [Int] {
            (0..<counters).map { cells[4 + $0] }
        }

        /// What the two runs without mutants showed about every switch, for the later processes of this unit (which
        /// do not make the two runs again): evaluated before the tests started, evaluated unequally often in the two
        /// runs, or evaluated equally often and at least once. A switch in none of the lists was not evaluated.
        private func writeClasses(launch: [Int], afterFirst: [Int], afterSecond: [Int]) {
            var atLaunch: [String] = []
            var uneven: [String] = []
            var even: [String] = []
            for id in 0..<counters {
                let inFirst = afterFirst[id] - launch[id]
                let inSecond = afterSecond[id] - afterFirst[id]
                if launch[id] != 0 {
                    atLaunch.append(String(id))
                } else if inFirst != inSecond {
                    uneven.append(String(id))
                } else if inSecond > 0 {
                    even.append(String(id))
                }
            }
            let text = "launch " + atLaunch.joined(separator: " ") + "\nuneven " + uneven.joined(separator: " ") + "\neven " + even.joined(separator: " ") + "\n"
            if FileManager.default.createFile(atPath: directory + "/classes.txt", contents: Data(text.utf8)) { emit("CLASSES") }
        }

        private func prepare() -> Bool {
            // The project's own test bundle: the copy inside the installed host app when there is one.
            var path = plan.bundlePath
            if let plugIns = Bundle.main.builtInPlugInsURL?.appendingPathComponent(plan.bundleName).path,
               FileManager.default.fileExists(atPath: plugIns) {
                path = plugIns
            }
            guard let bundle = Bundle(path: path) else {
                emit("STOP no test bundle at \(path)")
                return false
            }
            if !bundle.isLoaded, !bundle.load() {
                emit("STOP the test bundle could not be loaded: \(path)")
                return false
            }
            // XCTest creates one instance of the principal class that a test bundle names in its Info.plist, when it
            // loads the bundle; test targets use it to set things up once (observers, a mock server, global state).
            if !Self.principalMade, let name = bundle.infoDictionary?["NSPrincipalClass"] as? String, !name.isEmpty,
               let principal = NSClassFromString(name) as? NSObject.Type {
                Self.principalMade = true
                _ = principal.init()
            }
            allowActivities()
            bundlePath = path
            bundleSpellings = [path]
            var resolved = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
            let real = realpath(path, &resolved) != nil ? String(cString: resolved) : path
            for spelling in [bundle.bundlePath, real, URL(fileURLWithPath: path).resolvingSymlinksInPath().path] where !bundleSpellings.contains(spelling) {
                bundleSpellings.append(spelling)
            }

            if let getter = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "swt_abiv0_getEntryPoint") {
                typealias Getter = @convention(c) () -> UnsafeRawPointer
                swiftTesting = unsafeBitCast(unsafeBitCast(getter, to: Getter.self)(), to: Entry.self)
            }
            if plan.mode == "single" {
                emit("HELLO \(getpid()) \(swiftTesting == nil ? 0 : 1)")
                return true
            }

            let descriptor = open(plan.sharedPath, O_RDWR)
            guard descriptor >= 0 else {
                emit("STOP cannot open \(plan.sharedPath)")
                return false
            }
            let size = Int(lseek(descriptor, 0, SEEK_END))
            guard size >= 32, let memory = mmap(nil, size, PROT_READ | PROT_WRITE, MAP_SHARED, descriptor, 0), memory != MAP_FAILED else {
                emit("STOP cannot map \(plan.sharedPath)")
                return false
            }
            cells = memory.assumingMemoryBound(to: Int.self)
            counters = min(cells[2], size / 8 - 4)
            cells[0] = -1
            emit("HELLO \(getpid()) \(swiftTesting == nil ? 0 : 1)")
            return true
        }

        /// `XCTContext.runActivity` stops the process ("activities are disallowed in the current configuration")
        /// unless XCTest's active test configuration says that activities are reported. `xcodebuild` hands such a
        /// configuration to the test process; a host that the tool started has none. This makes one, through
        /// classes and selectors of XCTest that are not public: where one of them is missing nothing is done, the
        /// tests that use activities end the process as before, and the tool goes back to `xcodebuild`.
        private func allowActivities() {
            guard let type = NSClassFromString("XCTestConfiguration") as? NSObject.Type else { return emit("NOTE activities: no XCTestConfiguration class") }
            let active = NSSelectorFromString("activeTestConfiguration")
            let activate = NSSelectorFromString("setActiveTestConfiguration:")
            guard type.responds(to: active), type.responds(to: activate) else { return emit("NOTE activities: no active configuration to set") }
            var configuration = type.perform(active)?.takeUnretainedValue() as? NSObject
            var made = false
            if configuration == nil {
                let new = type.init()
                _ = type.perform(activate, with: new)
                configuration = new
                made = true
            }
            guard let configuration, configuration.responds(to: NSSelectorFromString("setReportActivities:")),
                  configuration.responds(to: NSSelectorFromString("reportActivities")) else { return emit("NOTE activities: the configuration has no such setting") }
            if (configuration.value(forKey: "reportActivities") as? Bool) != true {
                configuration.setValue(true, forKey: "reportActivities")
                emit("NOTE activities: allowed (\(made ? "a configuration was made" : "the configuration was changed"))")
            }
        }

        // MARK: One run of the tests

        private func pass(only mutantOnly: [String]?) -> XCMutatePass {
            let start = Date()
            var result = XCMutatePass()
            let only = mutantOnly ?? plan.only
            // Every selected test runs, also after a failure, as under xcodebuild: a later test may crash the process
            // (then the mutant is a Crash, decided by a process of its own), and the report names every failing test.
            runXCTest(only: only, into: &result)
            if plan.stopAtFirstFailure == true, !result.failed.isEmpty { result.seconds = Date().timeIntervalSince(start); return result }
            if result.completed { runSwiftTesting(only: only, into: &result) }
            result.seconds = Date().timeIntervalSince(start)
            return result
        }

        /// `-[Module.Class method]` → (`Class`, `method`), with the suffixes of throwing and async Swift methods removed.
        private func identifier(of test: XCTestCase) -> (type: String, method: String) {
            var text = test.name
            if text.hasPrefix("-[") { text.removeFirst(2) }
            if text.hasSuffix("]") { text.removeLast() }
            let parts = text.split(separator: " ", maxSplits: 1).map(String.init)
            var type = parts.first ?? text
            if let dot = type.lastIndex(of: ".") { type = String(type[type.index(after: dot)...]) }
            var method = parts.count > 1 ? parts[1] : ""
            for suffix in ["AndReturnError:", "WithCompletionHandler:"] where method.hasSuffix(suffix) {
                method.removeLast(suffix.count)
            }
            return (type, method)
        }

        private func matches(_ list: [String], type: String, method: String) -> Bool {
            list.contains { $0 == type || $0 == type + "/" + method || $0 == type + "/" + method + "()" }
        }

        private func collect(_ test: XCTest, into list: inout [XCTestCase]) {
            if let suite = test as? XCTestSuite {
                for child in suite.tests { collect(child, into: &list) }
            } else if let testCase = test as? XCTestCase {
                list.append(testCase)
            }
        }

        private func runXCTest(only: [String], into result: inout XCMutatePass) {
            var all: [XCTestCase] = []
            // XCTest finds the classes of a bundle by the spelling of its path. Under a symbolic link (`/tmp`, `/var`)
            // the spelling in the `.xctestrun` file and the one the loaded bundle reports can differ.
            for path in bundleSpellings where all.isEmpty {
                collect(XCTestSuite(forBundlePath: path), into: &all)
            }
            var order: [ObjectIdentifier] = []
            var groups: [ObjectIdentifier: (type: XCTestCase.Type, tests: [XCTestCase])] = [:]
            for test in all {
                let name = identifier(of: test)
                if !only.isEmpty, !matches(only, type: name.type, method: name.method) { continue }
                if matches(plan.skip, type: name.type, method: name.method) { continue }
                let key = ObjectIdentifier(type(of: test))
                if groups[key] == nil {
                    order.append(key)
                    groups[key] = (type(of: test), [])
                }
                groups[key]?.tests.append(test)
            }
            for key in order {
                guard let group = groups[key] else { continue }
                group.type.setUp()
                for test in group.tests {
                    noteTestStart(test.name)
                    test.run()
                    result.tests += 1
                    if let run = test.testRun, !run.hasSucceeded {
                        let name = identifier(of: test)
                        result.failed.append(name.type + "/" + name.method + "()")
                        if plan.stopAtFirstFailure == true { break }
                    }
                }
                group.type.tearDown()
                if plan.stopAtFirstFailure == true, !result.failed.isEmpty { return }
            }
        }

        private func pattern(_ identifier: String) -> String {
            "^" + NSRegularExpression.escapedPattern(for: plan.moduleName + "." + identifier) + "(/|$)"
        }

        private func runSwiftTesting(only: [String], into result: inout XCMutatePass) {
            guard let swiftTesting else { return }
            var configuration: [String: Any] = ["parallel": false, "verbosity": -2]
            if !only.isEmpty { configuration["filter"] = only.map(pattern) }
            if !plan.skip.isEmpty { configuration["skip"] = plan.skip.map(pattern) }
            guard let json = try? JSONSerialization.data(withJSONObject: configuration) else {
                result.completed = false
                return
            }
            let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: json.count, alignment: 1)
            defer { buffer.deallocate() }
            json.copyBytes(to: buffer)
            let input = UnsafeRawBufferPointer(buffer)

            // functions: the IDs of test functions; ended: test functions that ran or were skipped; failed: IDs with an issue that is not known.
            struct State {
                var functions: Set<String> = []
                var ended: Set<String> = []
                var failed: [String] = []
                var runEnded = false
                var finished = false
            }
            let state = XCMutateBox(State())
            let testLog = self.testLog
            Task.detached {
                _ = try? await swiftTesting(input) { record in
                    guard let object = try? JSONSerialization.jsonObject(with: Data(record)) as? [String: Any],
                          let payload = object["payload"] as? [String: Any] else { return }
                    let kind = object["kind"] as? String
                    let payloadKind = payload["kind"] as? String
                    if kind == "test" {
                        if payloadKind == "function", let id = payload["id"] as? String { state.update { $0.functions.insert(id) } }
                        return
                    }
                    guard kind == "event" else { return }
                    let testID = payload["testID"] as? String
                    switch payloadKind {
                    case "testStarted":
                        if let testID { testLog.update { $0?.write(Data((testID + "\n").utf8)) } }
                    case "testEnded", "testSkipped":
                        if let testID { state.update { $0.ended.insert(testID) } }
                    case "issueRecorded":
                        let issue = payload["issue"] as? [String: Any]
                        let known = issue?["isKnown"] as? Bool ?? false
                        let failure = issue?["isFailure"] as? Bool ?? true
                        if !known, failure { state.update { $0.failed.append(testID ?? "?") } }
                    case "runEnded":
                        state.update { $0.runEnded = true }
                    default:
                        break
                    }
                }
                state.update { $0.finished = true }
            }
            // The test method is on the main thread: keep the main run loop (and with it the main actor) turning.
            while !state.get().finished {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.002))
            }
            let final = state.get()
            if !final.runEnded { result.completed = false }
            result.tests += final.ended.intersection(final.functions).count
            var seen: Set<String> = []
            for id in final.failed where seen.insert(id).inserted {
                // `Module.Suite/test()/File.swift:1:2` → `Suite/test()`
                var parts = id.split(separator: "/").map(String.init)
                if let last = parts.last, last.contains(".swift:") { parts.removeLast() }
                var text = parts.joined(separator: "/")
                if text.hasPrefix(plan.moduleName + ".") { text.removeFirst(plan.moduleName.count + 1) }
                result.failed.append(text)
            }
        }
    }
    """#
}
