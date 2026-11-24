import Foundation
@testable import MutatorCore
@testable import MutatorRunner
import Testing

@Suite("Shared processes and workers")
struct SharedProcessTests {
    // MARK: What the driver reports

    static func events(_ text: String) -> SharedProcess.Events {
        var events = SharedProcess.Events()
        for line in text.split(separator: "\n") { events.consume(String(line)) }
        return events
    }

    static let log = """
    HELLO 4242 1
    CONTROL 1 ok 94 0.21
    CONTROL 2 ok 94 0.15
    SKIP 6 launch
    SKIP 30 uneven
    SKIP 31 unreached
    BEGIN 0
    END 0 fail 3 94 0.05\tCartTests/testTotal()\tCartTests/testEmpty()
    CHECK 0 ok 94 0.14
    DIRECT 0
    SETTLED 0
    BEGIN 1
    END 1 pass 2 94 0.15
    SETTLED 1
    BEGIN 2
    END 2 pass 0 94 0.15
    SETTLED 2
    BEGIN 3
    END 3 fail 0 7 0.02\tA/b()
    CHECK 3 ok 94 0.14
    SETTLED 3
    BEGIN 4
    END 4 error 1 90 0.15
    CHECK 4 ok 94 0.14
    SETTLED 4
    BEGIN 5
    END 5 fail 1 3 0.01\tA/c()
    """

    @Test func eventsAreParsed() {
        let events = Self.events(Self.log)
        #expect(events.processID == 4242)
        #expect(events.controlsPassed)
        #expect(events.controls[1]?.tests == 94)
        #expect(events.skipped == [6: "launch", 30: "uneven", 31: "unreached"])
        #expect(events.ended[0]?.failed == ["CartTests/testTotal()", "CartTests/testEmpty()"])
        #expect(events.ended[0]?.activations == 3)
        // #5 failed and its check run has not been reported: it is still the current mutant
        #expect(events.current == 5)
        #expect(!events.done)
    }

    @Test func verdictsFromAProcessThatEnded() {
        let events = Self.events(Self.log)
        func verdict(_ id: Int, _ ending: SharedProcess.Ending = .exited) -> SharedProcess.Verdict {
            SharedProcess.verdict(for: id, events: events, ending: ending)
        }
        // Failed with the switch active, and the tests passed again without it: the only case that is final
        #expect(verdict(0) == .killed(failed: ["CartTests/testTotal()", "CartTests/testEmpty()"], tests: 94, seconds: 0.05))
        #expect(verdict(1) == .survived(tests: 94, seconds: 0.15))
        func isAlone(_ v: SharedProcess.Verdict) -> Bool { if case .alone = v { true } else { false } }
        // Passed or failed without ever being evaluated as active: not a result of the mutant
        #expect(isAlone(verdict(2)))
        #expect(isAlone(verdict(3)))
        // A run with a different test count
        #expect(isAlone(verdict(4)))
        // Failed, but the process ended before the tests passed again without it
        #expect(isAlone(verdict(5)))
        // Evaluated at launch or unevenly
        #expect(isAlone(verdict(6)))
        #expect(isAlone(verdict(30)))
        // Not at all in this process: with one unit the executor runs it alone, with several it asks the other units
        #expect(verdict(31) == .unreached)
        // Never started: goes to the next process
        #expect(verdict(7) == .notRun)
    }

    /// A failing run that came after another mutant's passing run is a detection only if the mutant fails the
    /// tests again right after they have passed without mutants: the earlier mutant may have left state in the
    /// process (a singleton that its tearDown no longer clears) that fails the test, and the failing run may clear it.
    @Test func aFailingRunAfterAnotherMutantCountsOnlyWhenItFailsAgain() {
        func events(_ tail: String) -> SharedProcess.Events {
            Self.events("HELLO 1 0\nCONTROL 1 ok 3 0.1\nCONTROL 2 ok 3 0.1\nBEGIN 3\nEND 3 pass 2 3 0.1\nSETTLED 3\nBEGIN 4\nEND 4 fail 2 3 0.1\tStoreTests/testAddA()\nCHECK 4 ok 3 0.1\n" + tail)
        }
        func isAlone(_ v: SharedProcess.Verdict, _ text: String) -> Bool { if case let .alone(reason) = v { text.isEmpty || reason.contains(text) } else { false } }
        // Passed the second time: the first failure was not the mutant's doing
        let passedAgain = events("AGAIN 4 pass 2 3 0.1\nSETTLED 4\nDONE\n")
        #expect(isAlone(SharedProcess.verdict(for: 4, events: passedAgain, ending: .done), "state left by an earlier mutant"))
        #expect(passedAgain.current == nil)
        // Failed again, and the tests passed without it afterwards: detected
        let failedAgain = events("AGAIN 4 fail 2 3 0.2\tStoreTests/testAddA()\nCHECK2 4 ok 3 0.1\nSETTLED 4\nDONE\n")
        #expect(SharedProcess.verdict(for: 4, events: failedAgain, ending: .done) == .killed(failed: ["StoreTests/testAddA()"], tests: 3, seconds: 0.1 + 0.2))
        // Failed again without the switch being evaluated as active, or the tests do not pass afterwards: not judged here
        #expect(isAlone(SharedProcess.verdict(for: 4, events: events("AGAIN 4 fail 0 3 0.2\tA/b()\nCHECK2 4 ok 3 0.1\nSETTLED 4\nDONE\n"), ending: .done), "second time"))
        #expect(isAlone(SharedProcess.verdict(for: 4, events: events("AGAIN 4 fail 2 3 0.2\tA/b()\nCHECK2 4 fail 3 0.1\nSTOP dirty\nDONE\n"), ending: .done), ""))
        // The second run ran another number of tests
        #expect(isAlone(SharedProcess.verdict(for: 4, events: events("AGAIN 4 error 2 2 0.2\nCHECK2 4 ok 3 0.1\nSETTLED 4\nDONE\n"), ending: .done), "second run"))
        // Not repeated at all (a driver that stopped): the failing run alone is not enough
        #expect(isAlone(SharedProcess.verdict(for: 4, events: events("SETTLED 4\nDONE\n"), ending: .done), "not confirmed"))
        // While the driver is still at it, the mutant is the current one and has no verdict that the executor may take
        let running = events("")
        #expect(running.current == 4)
        #expect(isAlone(SharedProcess.verdict(for: 4, events: running, ending: .exited), ""))
        // --confirm-kills none: the failing run counts as it is (no confirmation)
        #expect(SharedProcess.verdict(for: 4, events: events("SETTLED 4\nDONE\n"), ending: .done, confirmation: .none)
                == .killed(failed: ["StoreTests/testAddA()"], tests: 3, seconds: 0.1))
    }

    @Test func aCheckThatFailsDoesNotCountAsKilled() {
        let events = Self.events("""
        HELLO 1 0
        CONTROL 1 ok 3 0.1
        CONTROL 2 ok 3 0.1
        BEGIN 8
        END 8 fail 1 1 0.1\tA/b()
        CHECK 8 fail 3 0.1
        STOP dirty
        DONE
        """)
        #expect(events.done)
        #expect(events.stop == "dirty")
        guard case .alone = SharedProcess.verdict(for: 8, events: events, ending: .done) else {
            Issue.record("a mutant whose check run failed must be run alone")
            return
        }
    }

    @Test func aMutantThatWasRunningWhenTheProcessEndedIsRunAlone() {
        let events = Self.events("HELLO 1 0\nCONTROL 1 ok 3 0.1\nCONTROL 2 ok 3 0.1\nBEGIN 8\n")
        #expect(events.current == 8)
        for ending in [SharedProcess.Ending.exited, .timedOut] {
            guard case .alone = SharedProcess.verdict(for: 8, events: events, ending: ending) else {
                Issue.record("expected .alone for \(ending)")
                return
            }
        }
        #expect(SharedProcess.verdict(for: 9, events: events, ending: .exited) == .notRun)
    }

    @Test func aFailingRunInASharedProcessIsKilledOnTheDriversReport() {
        let summary = TestSummary(result: "Failed", totalTestCount: 94, passedTests: 93, failedTests: 1, skippedTests: 0, expectedFailures: 0,
                                  failures: [.init(test: "CartTests/testTotal()", message: "x")])
        var observation = MutantObservation(key: "k", id: 1, attempt: 1, exitStatus: 65, timedOut: false, summary: summary, activated: true,
                                            runnerErrorPattern: nil, durationSeconds: 0.1, timeoutSeconds: 30)
        observation.sharedProcess = true
        let baseline = BaselineEvidence(testCount: 94, passedTests: 94, skippedTests: 0)
        let judged = Judgement.classify(observation, baseline: baseline)
        #expect(judged.status == .killed)
        #expect(judged.killedBy == ["CartTests/testTotal()"])
        // Another number of tests than the baseline is not judged, as with one process per mutant
        #expect(Judgement.classify(observation, baseline: BaselineEvidence(testCount: 12, passedTests: 12, skippedTests: 0)).status == .runnerError)
        // Without the activation record it is never a result of the mutant
        observation.activated = false
        #expect(Judgement.classify(observation, baseline: baseline).status == .runnerError)
    }

    // MARK: Which target a shared process can serve

    static func options(only: [String] = [], skip: [String] = [], testArguments: [String] = []) -> XcodeOptions {
        XcodeOptions(container: [], scheme: "App", destination: "id=X", testPlan: nil, extraBuildArguments: [], extraTestArguments: testArguments,
                     onlyTesting: only, skipTesting: skip, buildSettings: [])
    }

    static var unit: [String: Any] { [
        "BlueprintName": "AppTests", "ProductModuleName": "AppTests", "TestHostPath": "__TESTROOT__/Debug-iphonesimulator/App.app",
        "TestBundlePath": "__TESTHOST__/PlugIns/AppTests.xctest", "SkipTestIdentifiers": ["SlowTests", "CartTests/testFlaky"],
        "EnvironmentVariables": ["TERM": "dumb"],
    ] }
    static var ui: [String: Any] { ["BlueprintName": "AppUITests", "IsUITestBundle": true, "TestBundlePath": "__TESTHOST__/PlugIns/AppUITests.xctest"] }

    @Test func oneUnitTestTargetIsServed() throws {
        let plist: [String: Any] = ["__xctestrun_metadata__": ["FormatVersion": 1], "AppTests": Self.unit, "AppUITests": Self.ui]
        let units = try SharedProcess.units(plist: plist, productsDirectory: "/p",
                                            options: Self.options(only: ["AppTests/CartTests", "AppTests/PriceTests/rounding()"], skip: ["AppTests/CartTests/testSlow"])).get()
        #expect(units.count == 1)
        let target = units[0]
        #expect(target.blueprintName == "AppTests")
        #expect(target.hostPath == "/p/Debug-iphonesimulator/App.app")
        #expect(target.isAppHosted)
        #expect(target.environment == ["TERM": "dumb"])
        #expect(target.bundlePath == "/p/Debug-iphonesimulator/App.app/PlugIns/AppTests.xctest")
        #expect(target.only == ["CartTests", "PriceTests/rounding()"])
        // --skip-testing and the identifiers that the test plan disables
        #expect(target.skip == ["CartTests/testSlow", "SlowTests", "CartTests/testFlaky"])
        #expect(target.configurationName == nil)
        // The whole target
        #expect(try SharedProcess.units(plist: plist, productsDirectory: "/p", options: Self.options(only: ["AppTests"])).get()[0].only == [])
    }

    @Test func aUITargetIsNotServedAndSeveralConfigurationsAreSeveralUnits() throws {
        let plist: [String: Any] = ["__xctestrun_metadata__": ["FormatVersion": 1], "AppTests": Self.unit, "AppUITests": Self.ui]
        func failure(_ plist: [String: Any], _ options: XcodeOptions) -> String? {
            if case let .failure(reason) = SharedProcess.units(plist: plist, productsDirectory: "/p", options: options) { return reason.description }
            return nil
        }
        // No selection: the UI target would run too
        #expect(failure(plist, Self.options())?.contains("UI test target") == true)
        #expect(failure(plist, Self.options(only: ["AppUITests"]))?.contains("UI test target") == true)
        // Leaving the UI target out makes it one unit
        #expect(failure(plist, Self.options(skip: ["AppUITests"])) == nil)
        #expect(failure(plist, Self.options(only: ["Other"]))?.contains("no test target") == true)

        let twoConfigurations: [String: Any] = ["TestConfigurations": [["Name": "ja", "TestTargets": [Self.unit]], ["Name": "en", "TestTargets": [Self.unit]]]]
        let both = try SharedProcess.units(plist: twoConfigurations, productsDirectory: "/p", options: Self.options()).get()
        #expect(both.map(\.configurationName) == ["ja", "en"])
        #expect(both.map(\.label) == ["ja / AppTests", "en / AppTests"])
        let chosen = try SharedProcess.units(plist: twoConfigurations, productsDirectory: "/p",
                                             options: Self.options(testArguments: ["-only-test-configuration", "en"])).get()
        #expect(chosen.map(\.configurationName) == ["en"])
    }

    @Test func theSessionXctestrunRunsOnlyTheDriverInTheSameHost() throws {
        let plist: [String: Any] = ["TestConfigurations": [["Name": "ja", "TestTargets": [Self.unit, Self.ui]], ["Name": "en", "TestTargets": [Self.unit]]],
                                    "__xctestrun_metadata__": ["FormatVersion": 2]]
        let target = try SharedProcess.units(plist: plist, productsDirectory: "/p",
                                             options: Self.options(only: ["AppTests"], testArguments: ["-only-test-configuration", "ja"])).get()[0]
        let session = SharedProcess.sessionPlist(plist, productsDirectory: "/p", target: target, driverBundle: "/w/Driver.xctest", environment: ["A": "1"])
        let configurations = try #require(session["TestConfigurations"] as? [[String: Any]])
        #expect(configurations.count == 1)
        let targets = try #require(configurations[0]["TestTargets"] as? [[String: Any]])
        #expect(targets.count == 1)
        let entry = targets[0]
        #expect(entry["TestBundlePath"] as? String == "/w/Driver.xctest")
        #expect(entry["TestHostPath"] as? String == "/p/Debug-iphonesimulator/App.app")
        #expect(entry["OnlyTestIdentifiers"] as? [String] == ["XCMutateSharedProcess/testRunMutants"])
        #expect(entry["SkipTestIdentifiers"] == nil)
        #expect(entry["EnvironmentVariables"] as? [String: String] == ["TERM": "dumb", "A": "1"])
    }

    @Test func theDriverIsCompiledForThePlatformOfTheTestBundle() {
        let output = """
        /p/AppTests.xctest/AppTests:
        Load command 10
              cmd LC_BUILD_VERSION
          cmdsize 32
         platform IOSSIMULATOR
            minos 18.0
              sdk 27.2
        """
        let version = SharedProcess.buildVersion(vtoolOutput: output)
        #expect(version?.platform == "IOSSIMULATOR")
        #expect(version?.minimumOS == "18.0")
        #expect(SharedProcess.toolchainTarget(platform: "IOSSIMULATOR", minimumOS: "18.0", architecture: "arm64")?.triple == "arm64-apple-ios18.0-simulator")
        #expect(SharedProcess.toolchainTarget(platform: "MACOS", minimumOS: "14.0", architecture: "arm64")?.sdk == "macosx")
        // Platforms that were not tried are not guessed
        #expect(SharedProcess.toolchainTarget(platform: "WATCHOSSIMULATOR", minimumOS: "11.0", architecture: "arm64") == nil)
        #expect(SharedProcess.requestedConfigurations(["-only-test-configuration", "en", "-only-test-configuration:ja", "-quiet"]) == ["en", "ja"])
    }

    // MARK: The embedded helper in a shared process

    /// A program with two switches is run with a shared region: the active mutant changes between calls without a new
    /// process, and evaluations are counted in the region.
    @Test func theHelperReadsTheActiveMutantFromTheSharedRegion() throws {
        guard ExecutionOracleTests.available else { return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("shared-process-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let original = """
        func classify(_ a: Int, _ b: Int) -> String { if a > b { return "more" } else { return "not more" } }
        """
        let result = process(original)
        let boundary = try #require(result.mutants.first { $0.operator == .boundary })
        // The driver's side: set cell 0 to the mutant, call, read the counters
        let main = """

        @_silgen_name("open") func testOpen(_ path: UnsafePointer<CChar>, _ flags: Int32) -> Int32
        @_silgen_name("mmap") func testMmap(_ a: UnsafeMutableRawPointer?, _ l: Int, _ p: Int32, _ f: Int32, _ fd: Int32, _ o: Int64) -> UnsafeMutableRawPointer?
        let cells = testMmap(nil, 8 * 16, 3, 1, testOpen(CommandLine.arguments[1], 2), 0)!.assumingMemoryBound(to: Int.self)
        var output = classify(2, 2)
        cells[0] = \(boundary.id)
        output += "," + classify(2, 2)
        cells[0] = -1
        output += "," + classify(2, 2)
        print(output, cells[1], cells[\(Instrumenter.sharedHeaderCount) + \(boundary.id)])
        """
        let source = dir.appendingPathComponent("main.swift")
        try (result.instrumented + main).write(to: source, atomically: true, encoding: .utf8)
        let executable = dir.appendingPathComponent("program")
        let compile = try #require(runProcess(ExecutionOracleTests.swiftc, ["swiftc", "-swift-version", "6", "-o", executable.path, source.path]))
        #expect(compile.status == 0, "\(compile.output)")
        let region = dir.appendingPathComponent("shared.bin")
        var cells = [Int](repeating: 0, count: 16)
        cells[0] = -1
        cells[2] = 12
        try cells.withUnsafeBytes { Data($0) }.write(to: region)
        let run = try #require(runProcess(executable.path, [region.path], environment: [Instrumenter.sharedEnvironmentVariable: region.path]))
        // off, on (`>` became `>=`), off again; evaluated once as active and three times in all
        #expect(run.output.trimmingCharacters(in: .whitespacesAndNewlines) == "not more,more,not more 1 3")
        // Without the region the same program behaves as before
        let plain = try #require(runProcess(executable.path, [region.path], environment: [:]))
        #expect(plain.output.contains("not more,not more,not more"))
    }

    // MARK: Worker simulators

    @Test func workerSimulatorNamesCarryTheOwningProcess() {
        let name = SimulatorWorkers.name(processID: 4321, index: 2)
        #expect(name == "xcmutate-4321-w2")
        #expect(SimulatorWorkers.owner(ofName: name) == 4321)
        // Anything else is never taken for a worker simulator
        for other in ["iPhone 16", "xcmutate", "xcmutate-abc-w1", "xcmutate-12-x1", "xcmutate-12-w1-copy", "My-Worker-2"] {
            #expect(SimulatorWorkers.owner(ofName: other) == nil, "\(other)")
        }
    }

    @Test func onlyWorkerSimulatorsOfRunsThatAreGoneAreOrphans() throws {
        let json = Data("""
        {"devices": {"com.apple.CoreSimulator.SimRuntime.iOS-27-2": [
          {"udid": "A", "name": "iPhone 16", "state": "Booted", "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-16"},
          {"udid": "B", "name": "xcmutate-100-w1", "state": "Booted", "deviceTypeIdentifier": "t"},
          {"udid": "C", "name": "xcmutate-200-w1", "state": "Shutdown", "deviceTypeIdentifier": "t"},
          {"udid": "D", "name": "Pool-Worker-3", "state": "Shutdown", "deviceTypeIdentifier": "t"}
        ]}}
        """.utf8)
        let orphans = SimulatorWorkers.orphans(simctlJSON: json) { $0 == 100 }
        #expect(orphans == [SimulatorWorkers.Device(udid: "C", name: "xcmutate-200-w1")])
        let template = try #require(SimulatorWorkers.template(udid: "a", simctlJSON: json))
        #expect(template.deviceType == "com.apple.CoreSimulator.SimDeviceType.iPhone-16")
        #expect(template.runtime == "com.apple.CoreSimulator.SimRuntime.iOS-27-2")
        #expect(SimulatorWorkers.template(udid: "Z", simctlJSON: json) == nil)
    }
}
