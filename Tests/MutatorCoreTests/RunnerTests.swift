import Foundation
@testable import MutatorCore
@testable import MutatorRunner
import Testing

@Suite("実行部品（シミュレータ不要）")
struct RunnerTests {
    @Test func parsesCompilerErrorsFromBuildLog() {
        let log = """
        CompileSwift normal arm64 /work/src/A.swift
        /work/src/A.swift:12:30: error: referencing operator function '!=' requires that 'Token' conform to 'BinaryInteger'
        /work/src/A.swift:12:30: error: referencing operator function '!=' requires that 'Token' conform to 'BinaryInteger'
        /work/src/B.swift:3:1: warning: unused variable
        /work/src/Dir With Space/C.swift:7:2: error: missing return
        error: Filename "X.swift" used twice
        """
        let errors = CompilerDiagnostic.errors(inLog: log)
        #expect(errors.map { "\($0.path):\($0.line):\($0.column)" } == ["/work/src/A.swift:12:30", "/work/src/Dir With Space/C.swift:7:2"])
    }

    @Test func readsTraceFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("trace-\(UUID().uuidString)")
        try "R 1\nR 2\nA 3\ngarbage\nR 4\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let trace = Trace.read(url)
        #expect(trace.reached == [1, 2, 3, 4])
        #expect(trace.activated == [3])
        #expect(Trace.read(url.appendingPathExtension("missing")).reached.isEmpty)
    }

    @Test func crashDetectionInSummary() {
        let crash = TestSummary(result: "Failed", totalTestCount: 3, passedTests: 2, failedTests: 1, skippedTests: 0, expectedFailures: 0,
                                failures: [.init(test: "T/test()", message: "SampleApp (1234) encountered an error (Crash: SampleApp at TestKinds.element)")])
        #expect(crash.hasCrash)
        let assertion = TestSummary(result: "Failed", totalTestCount: 3, passedTests: 2, failedTests: 1, skippedTests: 0, expectedFailures: 0,
                                    failures: [.init(test: "T/test()", message: "XCTAssertEqual failed: (\"1\") is not equal to (\"0\")")])
        #expect(!assertion.hasCrash)
    }

    @Test func simulatorUDIDFromDestination() {
        let options = XcodeOptions(container: [], scheme: nil, destination: "platform=iOS Simulator,id=ABC-123", testPlan: nil,
                                   extraBuildArguments: [], extraTestArguments: [], onlyTesting: [], skipTesting: [], buildSettings: [])
        #expect(Xcode(options: options, derivedData: URL(fileURLWithPath: "/tmp")).simulatorUDID == "ABC-123")
    }

    @Test func subprocessTimeoutKillsProcessGroup() throws {
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("sub-\(UUID().uuidString).log").path
        defer { try? FileManager.default.removeItem(atPath: log) }
        // 子プロセスの孫（sleep）までグループごと止まること
        let outcome = try Subprocess.run(["/bin/sh", "-c", "sleep 30 & sleep 30; echo never"], logPath: log, timeout: 1)
        #expect(outcome.timedOut)
        // SIGTERM is enough: the child does not inherit "ignore SIGTERM", so there is no wait for SIGKILL
        #expect(outcome.duration < 3)
        let ok = try Subprocess.run(["/bin/sh", "-c", "echo hello; exit 3"], logPath: log)
        #expect(ok.status == 3)
        #expect(!ok.timedOut)
        #expect(try String(contentsOfFile: log, encoding: .utf8) == "hello\n")
    }

    /// A child that ignores SIGTERM itself is killed after the grace period, or at once when nothing it writes is needed.
    @Test func aChildThatIgnoresSIGTERMIsKilled() throws {
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("sub-\(UUID().uuidString).log").path
        defer { try? FileManager.default.removeItem(atPath: log) }
        let stubborn = ["/bin/sh", "-c", "trap '' TERM; sleep 30 & wait"]
        let graceful = try Subprocess.run(stubborn, logPath: log, timeout: 0.5, stop: .graceful(seconds: 1))
        #expect(graceful.timedOut)
        #expect(graceful.duration > 1.4 && graceful.duration < 4, "\(graceful.duration)")
        let immediate = try Subprocess.run(stubborn, logPath: log, timeout: 0.5, stop: .immediate)
        #expect(immediate.timedOut)
        #expect(immediate.duration < 1.5, "\(immediate.duration)")
        #expect(immediate.status == 128 + SIGKILL)
    }

    /// The tool ignores SIGINT, SIGTERM and SIGHUP in itself (it handles them through Dispatch). A child must
    /// not inherit that, or the signals that stop it do nothing. This runs in a process of its own (`/bin/sh` with
    /// the signals ignored, which starts the test's command through the tool's own spawn is not possible), so the
    /// check is on the disposition that a child reports: `trap` lists nothing as ignored.
    @Test func childrenGetTheDefaultSignalActions() throws {
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("sub-\(UUID().uuidString).log").path
        defer { try? FileManager.default.removeItem(atPath: log) }
        // Ignore the signals in this process for the length of the spawn, as `InterruptHandler.install()` does
        let signals = [SIGTERM, SIGHUP]
        let previous = signals.map { signal($0, SIG_IGN) }
        defer { for (sig, handler) in zip(signals, previous) { signal(sig, handler) } }
        // A shell started with a signal ignored cannot trap or reset it and keeps ignoring it: SIGTERM would not end it
        let outcome = try Subprocess.run(["/bin/sh", "-c", "sleep 30"], logPath: log, timeout: 0.5, stop: .graceful(seconds: 20))
        #expect(outcome.timedOut)
        #expect(outcome.duration < 3, "SIGTERM did not stop the child: \(outcome.duration)s")
    }

    /// The line of the log that says what went wrong is shown, with what to do about it where that is known.
    @Test func aBuildFailureShowsWhatXcodebuildSaid() {
        let scheme = RunSession.buildFailureWithoutCompilerErrors(log: """
        Command line invocation:
            /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild build-for-testing -scheme NoSuchScheme
        xcodebuild: error: The project named "StockKit" does not contain a scheme named "NoSuchScheme". The "-list" option can be used to find the names of the schemes in the project.
        """)
        #expect(scheme.contains("does not contain a scheme named \"NoSuchScheme\""))
        #expect(scheme.contains("Check --scheme"))
        #expect(scheme.contains("<name>-Package"))
        #expect(!scheme.contains("signing"))
        let signing = RunSession.buildFailureWithoutCompilerErrors(log: "error: Signing for \"App\" requires a development team. Select a development team in the Signing & Capabilities editor. (in target 'App')\n** TEST BUILD FAILED **\n")
        #expect(signing.contains("CODE_SIGNING_ALLOWED=NO"))
        // Without Xcode (only the Command Line Tools, or a developer directory that does not exist)
        for log in ["xcrun: error: missing DEVELOPER_DIR path: /nonexistent\n",
                    "xcode-select: error: tool 'xcodebuild' requires Xcode, but active developer directory '/Library/Developer/CommandLineTools' is a command line tools instance\n"] {
            let missing = RunSession.buildFailureWithoutCompilerErrors(log: log)
            #expect(missing.contains("Xcode was not found"))
            #expect(missing.contains("xcode-select -s"))
        }
        let packages = RunSession.buildFailureWithoutCompilerErrors(log: "xcodebuild: error: Could not resolve package dependencies:\n  Authentication failed\n")
        #expect(packages.contains("--package-cache"))
        let unknown = RunSession.buildFailureWithoutCompilerErrors(log: "note: something\n** TEST BUILD FAILED **\n")
        #expect(unknown.contains("the log names no error"))
    }

    /// A scheme with several test plans: the file of this build is used, and the others are reported.
    @Test func theXctestrunOfThisBuildIsChosen() throws {
        try withTemporaryDirectory { directory in
            let products = directory.appendingPathComponent("Build/Products")
            try FileManager.default.createDirectory(at: products, withIntermediateDirectories: true)
            func make(_ name: String, age: TimeInterval) throws -> URL {
                let url = products.appendingPathComponent(name)
                try Data("x".utf8).write(to: url)
                try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path)
                return url
            }
            _ = try make("App_Old_iphonesimulator17.0-arm64.xctestrun", age: 86_400)
            let unit = try make("App_Unit_iphonesimulator18.0-arm64.xctestrun", age: 20)
            let full = try make("App_Full_iphonesimulator18.0-arm64.xctestrun", age: 10)
            func xcode(plan: String?) -> Xcode {
                Xcode(options: XcodeOptions(container: [], scheme: "App", destination: "id=X", testPlan: plan, extraBuildArguments: [], extraTestArguments: [],
                                            onlyTesting: [], skipTesting: [], buildSettings: []), derivedData: directory)
            }
            let start = Date().addingTimeInterval(-60)
            // No plan named: the newest file of this build, and the other file of this build is reported (not the old one)
            let chosen = xcode(plan: nil).xctestrun(since: start)
            #expect(chosen.chosen?.lastPathComponent == full.lastPathComponent)
            #expect(chosen.others.map(\.lastPathComponent) == [unit.lastPathComponent])
            // A plan named: its file, nothing to report
            let named = xcode(plan: "Unit").xctestrun(since: start)
            #expect(named.chosen?.lastPathComponent == unit.lastPathComponent)
            #expect(named.others.isEmpty)
            // Nothing from this build (the build was up to date): the newest of what is there
            #expect(xcode(plan: nil).xctestrun(since: Date()).chosen?.lastPathComponent == full.lastPathComponent)
            #expect(xcode(plan: nil).xctestrun()?.lastPathComponent == full.lastPathComponent)
        }
    }

    @Test func workCopyContainsOnlyTrackedAndUntrackedFiles() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("wc-\(UUID().uuidString)")
        let repo = base.appendingPathComponent("repo")
        try fm.createDirectory(at: repo.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        try "a".write(to: repo.appendingPathComponent("Sources/A.swift"), atomically: true, encoding: .utf8)
        try ".build/\n".write(to: repo.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try fm.createDirectory(at: repo.appendingPathComponent(".build"), withIntermediateDirectories: true)
        try "x".write(to: repo.appendingPathComponent(".build/junk"), atomically: true, encoding: .utf8)
        _ = try Subprocess.capture(["git", "-C", repo.path, "init", "-q"])
        _ = try Subprocess.capture(["git", "-C", repo.path, "add", "Sources/A.swift", ".gitignore"])
        try "b".write(to: repo.appendingPathComponent("Sources/B.swift"), atomically: true, encoding: .utf8)  // 未追跡
        let copy = base.appendingPathComponent("copy")
        let count = try WorkCopy.create(from: repo, to: copy)
        #expect(count == 3)
        #expect(fm.fileExists(atPath: copy.appendingPathComponent("Sources/B.swift").path))
        #expect(!fm.fileExists(atPath: copy.appendingPathComponent(".build/junk").path))
        #expect(!fm.fileExists(atPath: copy.appendingPathComponent(".git").path))
    }

    @Test func reportsAndScore() throws {
        let source = "func f(_ a: Int) -> Bool {\n    a > 0 && a < 9\n}\n"
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try source.write(to: dir.appendingPathComponent("F.swift"), atomically: true, encoding: .utf8)
        let mutants = FileProcessor(options: basicOperatorOptions).process(source: source, file: "F.swift", firstID: 0).mutants
        #expect(mutants.count == 3)
        let statuses: [MutantStatus] = [.killed, .survived, .notReached]
        let results = zip(mutants, statuses).map { MutantResult(mutant: $0, status: $1, killedBy: [], durationSeconds: 1, attempts: 1, detail: nil) }
            + [MutantResult(mutant: mutants[0], status: .runnerError, killedBy: [], durationSeconds: 1, attempts: 2, detail: "x")]
        let report = RunReport(scope: "all", root: dir.path, files: ["F.swift"], skippedFiles: [:], baseline: nil,
                               durations: RunDurations(), results: results, ignored: [], warnings: [])
        #expect(report.score == 1.0 / 3.0)
        #expect(report.counts == ["Killed": 1, "Survived": 1, "NotReached": 1, "RunnerError": 1])

        let agent = AgentReport(report: report)
        #expect(agent.gaps.map(\.gap) == ["notDetected", "notReached"])
        #expect(agent.scopes.count == 1)
        #expect(agent.scopes.first?.startLine == 1)
        #expect(agent.scopes.first?.endLine == 3)
        #expect(agent.scopes.first?.source == "    1| func f(_ a: Int) -> Bool {\n    2|     a > 0 && a < 9\n    3| }")
        #expect(agent.fixes["notReached"]?.hasPrefix("No test executes") == true)
        #expect(agent.warnings.contains { $0.kind == "runnerError" })
        let text = TextReport.render(report)
        #expect(text.contains("mutation score: 33.3%"))
        #expect(text.contains("key: \(mutants[1].key)"))
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(JSONReport(report: report))) as? [String: Any]
        #expect(json?["score"] as? Double == 1.0 / 3.0)
        #expect((json?["results"] as? [Any])?.count == 4)
    }
}
