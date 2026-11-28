import Foundation
import Testing
@testable import MutatorCore
@testable import MutatorRunner

/// `xcmutate init` (what it chooses and where it puts things), the worker simulators' privacy settings, the time
/// breakdown with several workers, and a host started by the tool that goes to the background.
@Suite("init, workers, breakdown, background")
struct InitAndTimingTests {
    static func facts(simulator: Bool = true) -> ProjectSetup.Facts {
        var facts = ProjectSetup.Facts(container: ("project", "App.xcodeproj"), scheme: "App", destination: simulator ? "id=0000-AAAA" : "platform=macOS", isSimulator: simulator)
        facts.cores = 16
        facts.memoryGB = 64
        facts.impactMap = (".build/xcmutate/impact.json", "in .build, which git ignores")
        return facts
    }

    static func trial(seconds: Double, startup: Double = 0, executed: Int = 10, mutants: Int = 10, baseline: Double = 60) -> ProjectSetup.Trial {
        var trial = ProjectSetup.Trial(exitCode: 0)
        for index in 0..<mutants { trial.statuses["k\(index)"] = index < executed ? "Killed" : "NotReached" }
        trial.testCount = 100
        trial.baselineSeconds = baseline
        trial.finalBaselineSeconds = baseline
        trial.phaseSeconds = seconds
        trial.startupSeconds = startup
        trial.executed = executed
        trial.mutants = mutants
        trial.secondsPerMutant = executed > 0 ? max(seconds - startup, 0) / Double(executed) : nil
        return trial
    }

    static let fastOptions = ["--select-tests", "reach", "--shared-process"]

    /// A faster mode that was slower in the trial is not chosen, even with the same verdicts (on an app the faster
    /// modes took 215.9 s against 140 s and were chosen); the runs without mutants at the start of a shared process
    /// do not count against it, because they are paid once per process.
    @Test func aFasterModeThatWasSlowerInTheTrialIsNotChosen() {
        let plain = Self.trial(seconds: 140)
        let slower = ProjectSetup.recommend(facts: Self.facts(), plain: plain, fast: Self.trial(seconds: 215.9), fastOptions: Self.fastOptions)
        #expect(slower.profiles["pr"]?["sharedProcess"] == nil && slower.profiles["nightly"]?["sharedProcess"] == nil)
        #expect(slower.reasons.contains { $0.contains("was not faster: 21.6 s per mutant against 14.0 s") })
        // 215.9 s of which 120 s are the two runs at the start of the process: 9.6 s per mutant
        let faster = ProjectSetup.recommend(facts: Self.facts(), plain: plain, fast: Self.trial(seconds: 215.9, startup: 120), fastOptions: Self.fastOptions)
        #expect(faster.profiles["pr"]?["sharedProcess"] as? String == "auto" && faster.profiles["nightly"]?["sharedProcess"] as? Bool == true)
        // No mutant run: nothing shows it to be faster
        let none = ProjectSetup.recommend(facts: Self.facts(), plain: Self.trial(seconds: 0, executed: 0), fast: Self.trial(seconds: 0, executed: 0), fastOptions: Self.fastOptions)
        #expect(none.profiles["nightly"]?["sharedProcess"] == nil)
    }

    /// The estimate counts what does not grow with the number of mutants once, and the time per mutant only for the
    /// share of mutants that were run (50 mutants were estimated at 183 minutes; 33 took 22).
    @Test func theEstimateSeparatesFixedCostsFromTheCostPerMutant() {
        // 10 of 20 mutants run, 300 s of which 120 s at the start of the process: 18 s each; 60 + 60 + 120 s fixed
        let estimate = ProjectSetup.estimate(plain: Self.trial(seconds: 400), fast: Self.trial(seconds: 300, startup: 120, executed: 10, mutants: 20), mutants: 50)
        // 240 + 18 × 50 × 0.5 = 690 s
        #expect(estimate.hasPrefix("a pull request with 50 mutants: roughly 12 minutes after the build"))
        #expect(estimate.contains("10 of 20 mutants were run, 18.0 s each; 240 s do not depend on the number of mutants"))
        #expect(ProjectSetup.estimate(plain: Self.trial(seconds: 0, executed: 0), fast: nil, mutants: 50).hasPrefix("no estimate"))
    }

    /// The trial's numbers come from its JSON report: the runs at the start of shared processes are taken out of the
    /// time per mutant.
    @Test func theTrialReadsTheTimePerMutantWithoutTheStartOfSharedProcesses() {
        let report: [String: Any] = [
            "results": [["mutant": ["key": "a"], "status": "Killed"], ["mutant": ["key": "b"], "status": "NotReached"], ["mutant": ["key": "c"], "status": "RunnerError"]],
            "baseline": ["testCount": 12, "durationSeconds": 30.0],
            "durations": ["mutantPhaseSeconds": 100.0, "executedMutants": 2, "finalBaselineSeconds": 31.0, "breakdown": ["startupRunSeconds": 60.0]],
        ]
        let trial = ProjectSetup.read(report: report, into: ProjectSetup.Trial(exitCode: 0))
        #expect(trial.secondsPerMutant == 20 && trial.startupSeconds == 60 && trial.executed == 2 && trial.mutants == 3 && trial.finalBaselineSeconds == 31)
        #expect(trial.statuses == ["a": "Killed", "b": "NotReached"])
    }

    /// The sample is taken near the code being worked on: the files given, the directory of --path, or the current
    /// directory below the root; tests are left out as a run leaves them out. Only at the root is it the whole repository.
    @Test func theSampleIsTakenFromTheFilesOrTheDirectoryGiven() throws {
        try withTemporaryDirectory { root in
            let fm = FileManager.default
            for (path, text) in [("App/Cart/Cart.swift", "struct Cart {}"), ("App/Cart/Price.swift", "struct Price {}"), ("App/Other.swift", "struct Other {}"),
                                 ("AppTests/CartTests.swift", "import XCTest"), ("App/Cart/README.md", "x")] {
                let url = root.appendingPathComponent(path)
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try text.write(to: url, atomically: true, encoding: .utf8)
            }
            _ = runProcess("/usr/bin/git", ["-C", root.path, "init", "-q"])
            _ = runProcess("/usr/bin/git", ["-C", root.path, "add", "-A"])
            func options(cwd: URL, files: [String] = [], path: String? = nil) -> ProjectSetup.Options {
                var options = ProjectSetup.Options(root: root, configFile: root.appendingPathComponent("c.json"), executable: "x", cwd: cwd)
                options.files = files
                options.path = path
                return options
            }
            #expect(try ProjectSetup.sampleFiles(options(cwd: root), exclude: []).files.isEmpty)
            #expect(try ProjectSetup.sampleFiles(options(cwd: root, path: "App/Cart"), exclude: []).files == ["App/Cart/Cart.swift", "App/Cart/Price.swift"])
            #expect(try ProjectSetup.sampleFiles(options(cwd: root, path: "App/Cart"), exclude: ["**/Price.swift"]).files == ["App/Cart/Cart.swift"])
            #expect(try ProjectSetup.sampleFiles(options(cwd: root.appendingPathComponent("App")), exclude: []).files == ["App/Cart/Cart.swift", "App/Cart/Price.swift", "App/Other.swift"])
            #expect(try ProjectSetup.sampleFiles(options(cwd: root.appendingPathComponent("App"), files: ["Other.swift"]), exclude: []).files == ["App/Other.swift"])
            #expect(throws: ProjectSetup.Failure.self) { try ProjectSetup.sampleFiles(options(cwd: root, path: "AppTests"), exclude: []) }
            #expect(throws: ProjectSetup.Failure.self) { try ProjectSetup.sampleFiles(options(cwd: root, files: ["/elsewhere/A.swift"]), exclude: []) }
        }
    }

    /// Workers are recommended only when the simulator's privacy settings could be given to another simulator; the
    /// worker simulators of a run get them (a permission dialog there stopped shared processes, and a nightly run with
    /// workers took 1944 s instead of less).
    @Test func workersAreRecommendedOnlyWhenThePrivacySettingsCanBeCopied() {
        var facts = Self.facts()
        let plain = Self.trial(seconds: 140)
        #expect(ProjectSetup.recommend(facts: facts, plain: plain, fast: nil, fastOptions: []).profiles["nightly"]?["workers"] as? Int == 4)
        facts.workerPrivacyProblem = "kTCCServiceCamera for com.example.app (not a service that simctl privacy can set)"
        let without = ProjectSetup.recommend(facts: facts, plain: plain, fast: nil, fastOptions: [])
        #expect(without.profiles["nightly"]?["workers"] == nil)
        #expect(without.reasons.contains { $0.hasPrefix("nightly.workers: one simulator") && $0.contains("kTCCServiceCamera") })
        // The rows of the TCC database: allowed is a grant, denied a revoke, other apps and other values are left
        let rows = "kTCCServiceAll|com.example.app|2\nkTCCServicePhotos|com.example.app|0\nkTCCServiceCamera|com.example.app|2\nkTCCServicePhotos|com.example.app|3\nkTCCServiceAll|com.other|2\n"
        let privacy = SimulatorWorkers.privacy(tccRows: rows, bundles: ["com.example.app"])
        #expect(privacy.actions == [["grant", "all", "com.example.app"], ["revoke", "photos", "com.example.app"]])
        #expect(privacy.notCopied == ["kTCCServiceCamera for com.example.app", "kTCCServicePhotos for com.example.app"])
    }

    /// The destination is written by the simulator's name and OS version, which other Macs can resolve, when that names
    /// the one simulator; runtimes with more after the version (`iOS-27-2-iPhone19-4`) are read too.
    @Test func theDestinationIsWrittenByNameWhenTheNameIsUnique() throws {
        let json = #"""
        {"devices": {
          "com.apple.CoreSimulator.SimRuntime.iOS-27-2-iPhone19-4": [
            {"udid": "AAAA", "name": "iPhone Duo", "state": "Booted", "isAvailable": true},
            {"udid": "BBBB", "name": "Twin", "state": "Shutdown", "isAvailable": true},
            {"udid": "CCCC", "name": "Twin", "state": "Shutdown", "isAvailable": true}],
          "com.apple.CoreSimulator.SimRuntime.iOS-26-5": [
            {"udid": "DDDD", "name": "iPhone Duo", "state": "Shutdown", "isAvailable": true}]
        }}
        """#
        let data = Data(json.utf8)
        #expect(SimulatorCheck.runtimeVersion("com.apple.CoreSimulator.SimRuntime.iOS-27-2-iPhone19-4") == "27.2")
        #expect(SimulatorCheck.runtimeVersion("com.apple.CoreSimulator.SimRuntime.iOS-18-0") == "18.0")
        #expect(SimulatorCheck.destinationByName(udid: "AAAA", simctlJSON: data) == "platform=iOS Simulator,name=iPhone Duo,OS=27.2")
        #expect(SimulatorCheck.destinationByName(udid: "DDDD", simctlJSON: data) == "platform=iOS Simulator,name=iPhone Duo,OS=26.5")
        #expect(SimulatorCheck.destinationByName(udid: "BBBB", simctlJSON: data) == nil)
        var facts = Self.facts()
        facts.fileDestination = "platform=iOS Simulator,name=iPhone Duo,OS=27.2"
        let recommendation = ProjectSetup.recommend(facts: facts, plain: Self.trial(seconds: 10), fast: nil, fastOptions: [])
        #expect(recommendation.run["destination"] as? String == "platform=iOS Simulator,name=iPhone Duo,OS=27.2")
    }

    /// --build-arg, --package-cache and --work-dir given to init are written into `run`, and the config file hands a
    /// value that starts with `-` to the parser as `--build-arg=<value>`; `~/` in a path is the home directory.
    @Test func buildArgumentsPackageCacheAndWorkDirAreWrittenAndRead() throws {
        var facts = Self.facts()
        facts.buildArguments = ["-quiet", "OTHER_SWIFT_FLAGS=-DCI"]
        facts.packageCache = "../SourcePackages"
        facts.workDir = ".build/mutation"
        let run = ProjectSetup.recommend(facts: facts, plain: Self.trial(seconds: 10), fast: nil, fastOptions: []).run
        #expect(run["buildArg"] as? [String] == ["-quiet", "OTHER_SWIFT_FLAGS=-DCI"] && run["packageCache"] as? String == "../SourcePackages" && run["workDir"] as? String == ".build/mutation")
        try withTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("config.json")
            try #"{"run": {"buildArg": ["-quiet", "A=B"], "workDir": "~/w", "writeImpactMap": "~/Library/Caches/xcmutate/impact-App.json"}}"#.write(to: file, atomically: true, encoding: .utf8)
            let expansion = try RunProfile.expand(configAt: file, profile: nil, given: ["run"])
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            #expect(expansion.arguments == ["--build-arg=-quiet", "--build-arg", "A=B", "--work-dir", home + "/w", "--write-impact-map", home + "/Library/Caches/xcmutate/impact-App.json"])
            #expect(try RunProfile.expand(configAt: file, profile: nil, given: ["run", "--build-arg=-x"]).overridden == ["buildArg"])
        }
    }

    /// A relative path in the config file is relative to the file's directory (the root), wherever the run is started:
    /// a run from a subdirectory used `App/.build`, and `../w` pointed elsewhere. init writes the paths given to it
    /// relative to that directory.
    @Test func relativePathsOfTheConfigFileAreRelativeToItsDirectory() throws {
        try withTemporaryDirectory { directory in
            let root = directory.appendingPathComponent("repo")
            try FileManager.default.createDirectory(at: root.appendingPathComponent("App"), withIntermediateDirectories: true)
            let file = root.appendingPathComponent("xcmutate.config.json")
            try #"{"run": {"workDir": ".build/mutation", "packageCache": "../SourcePackages", "scheme": "App"}, "profiles": {"nightly": {"writeImpactMap": "/abs/impact.json"}}}"#.write(to: file, atomically: true, encoding: .utf8)
            let expansion = try RunProfile.expand(configAt: file, profile: "nightly", given: ["run"])
            let base = file.deletingLastPathComponent().standardizedFileURL.path
            let parent = file.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL.path
            #expect(expansion.arguments == ["--package-cache", parent + "/SourcePackages", "--scheme", "App", "--work-dir", base + "/.build/mutation", "--write-impact-map", "/abs/impact.json"])
            // init started in App/ with --work-dir ../.build/m and --package-cache ../../cache
            var options = ProjectSetup.Options(root: root, configFile: file, executable: "x", cwd: root.appendingPathComponent("App"))
            options.workDir = "../.build/m"
            #expect(ProjectSetup.forFile("../.build/m", options) == ".build/m")
            #expect(ProjectSetup.forFile("../../cache", options) == "../cache")
            #expect(ProjectSetup.forFile(".", options) == "App")
            #expect(ProjectSetup.forFile("~/w", options) == "~/w" && ProjectSetup.forFile("/Volumes/w", options) == "/Volumes/w")
        }
        #expect(ProjectSetup.relativePath(from: "/a/b", to: "/a/b") == "." && ProjectSetup.relativePath(from: "/a/b", to: "/a/c/d") == "../c/d")
    }

    /// --workers with a simulator destination by name that does not name one simulator on this Mac stops the run
    /// before the build; it used to be taken for a Mac, and the workers shared one simulator.
    @Test func workersRefuseASimulatorNameThatIsNotOneSimulator() {
        let json = Data(#"""
        {"devices": {
          "com.apple.CoreSimulator.SimRuntime.iOS-27-2": [
            {"udid": "BBBB", "name": "Twin", "state": "Booted", "isAvailable": true},
            {"udid": "CCCC", "name": "Twin", "state": "Shutdown", "isAvailable": true},
            {"udid": "DDDD", "name": "Solo", "state": "Booted", "isAvailable": true}]
        }}
        """#.utf8)
        #expect(SimulatorCheck.workersRefusal(forDestination: "platform=iOS Simulator,name=Solo,OS=27.2", simctlJSON: json) == nil)
        #expect(SimulatorCheck.workersRefusal(forDestination: "platform=iOS Simulator,name=Twin,OS=27.2", simctlJSON: json)?.contains("names 2 simulators on this Mac (BBBB Booted, CCCC Shutdown)") == true)
        #expect(SimulatorCheck.workersRefusal(forDestination: "platform=iOS Simulator,name=Other", simctlJSON: json)?.contains("names no simulator") == true)
        #expect(SimulatorCheck.workersRefusal(forDestination: "platform=iOS Simulator,name=Solo,OS=26.0", simctlJSON: json)?.contains("names no simulator") == true)
        #expect(SimulatorCheck.workersRefusal(forDestination: "platform=macOS", simctlJSON: json) == nil)
        #expect(SimulatorCheck.workersRefusal(forDestination: "id=EEEE", simctlJSON: json) == nil)
    }

    /// The impact map is never written into what git tracks (it made the working tree dirty, and the next map was
    /// filed under a commit that did not hold it), nor into a work directory (`clean` removes those); two checkouts
    /// with the same name get maps of their own.
    @Test func theImpactMapIsWrittenOutsideWhatGitTracks() {
        let root = URL(fileURLWithPath: "/repos/App")
        #expect(ProjectSetup.impactMapPath(root: root) { $0.hasPrefix(".build/") }.path == ".build/xcmutate/impact.json")
        let home = ProjectSetup.impactMapPath(root: root) { _ in false }.path
        #expect(home.hasPrefix("~/Library/Caches/xcmutate/impact-App-") && home.hasSuffix(".json"))
        #expect(home != ProjectSetup.impactMapPath(root: URL(fileURLWithPath: "/other/App")) { _ in false }.path)
        let nightly = ProjectSetup.recommend(facts: Self.facts(), plain: Self.trial(seconds: 10), fast: nil, fastOptions: []).profiles["nightly"]
        #expect(nightly?["writeImpactMap"] as? String == ".build/xcmutate/impact.json")
    }

    /// A full disk is said as such, and a failed init removes what it built and keeps only its logs; the lock files
    /// that xcodebuild leaves in the temporary directory for a DerivedData directory are found by its path alone.
    @Test func aFullDiskIsSaidAndWhatInitLeftIsRemoved() throws {
        #expect(ProjectSetup.saysDiskFull("error: unable to write file: No space left on device"))
        #expect(!ProjectSetup.saysDiskFull("Test Suite 'All tests' failed"))
        // In the output of a trial only the lines that report errors count: a test may print anything
        let trial = "Test Case 'StorageTests.testFullDisk' started\nsimulated: No space left on device\nTest Case passed\n"
        #expect(!ProjectSetup.saysDiskFull(trial, errorLinesOnly: true))
        #expect(ProjectSetup.saysDiskFull(trial + "xcodebuild: error: failed to write: No space left on device\n", errorLinesOnly: true))
        #expect(ProjectSetup.saysDiskFull("xcmutate: the work copy could not be made: ENOSPC\n", errorLinesOnly: true))
        #expect(!ProjectSetup.saysDiskFull("error: the cart is out of space\n", errorLinesOnly: true))
        try withTemporaryDirectory { work in
            let fm = FileManager.default
            try fm.createDirectory(at: work.appendingPathComponent("DerivedData/Build"), withIntermediateDirectories: true)
            try "log".write(to: work.appendingPathComponent("build.log"), atomically: true, encoding: .utf8)
            try "{}".write(to: work.appendingPathComponent("plain.json"), atomically: true, encoding: .utf8)
            ProjectSetup.cleanUp(work, keepLogs: true)
            #expect(try fm.contentsOfDirectory(atPath: work.path) == ["build.log"])
            ProjectSetup.cleanUp(work, keepLogs: false)
            #expect(!fm.fileExists(atPath: work.path))
        }
        let derivedData = URL(fileURLWithPath: "/work/w/DerivedData")
        let names = ["_work_w_DerivedData_SourcePackages_Package.resolved.lock", "_work_w_DerivedData_SourcePackages_workspace-state.json.lock",
                     "_work_w2_DerivedData_SourcePackages_Package.resolved.lock", "_work_w_DerivedData_SourcePackages_Package.resolved", "other.lock"]
        #expect(PackageLockFiles.names(derivedData: derivedData, among: names) == Array(names.prefix(2)))
        // Below the location that `xcodebuild -list` is given (IDECustomDerivedDataLocation)
        let listed = ["_work_l_App-abc_SourcePackages_workspace-state.json.lock", "_work_l2_App-abc_SourcePackages_workspace-state.json.lock", "_work_l_App-abc_other.lock"]
        #expect(PackageLockFiles.names(under: URL(fileURLWithPath: "/work/l"), among: listed) == [listed[0]])
    }

    /// What an init that was killed left is removed by the next one; that of an init still running is not.
    @Test func theNextInitRemovesWhatAKilledOneLeft() throws {
        let finished = Process()
        finished.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try finished.run()
        finished.waitUntilExit()
        try withTemporaryDirectory { base in
            let fm = FileManager.default
            let dead = base.appendingPathComponent("\(ProjectSetup.workPrefix)\(finished.processIdentifier)")
            let mine = base.appendingPathComponent("\(ProjectSetup.workPrefix)\(getpid())")
            let alive = base.appendingPathComponent("\(ProjectSetup.workPrefix)1")   // launchd
            let other = base.appendingPathComponent("unrelated-\(finished.processIdentifier)")
            for directory in [dead, mine, alive, other] { try fm.createDirectory(at: directory.appendingPathComponent("DerivedData"), withIntermediateDirectories: true) }
            ProjectSetup.removeOrphanWork(in: base)
            #expect(!fm.fileExists(atPath: dead.path))
            #expect(fm.fileExists(atPath: mine.path) && fm.fileExists(atPath: alive.path) && fm.fileExists(atPath: other.path))
        }
    }

    static func parts(startup: Double = 0, recheck: Double = 0, control: Double = 0, own: Double = 0, final: Double = 0) -> RunDurations.Breakdown {
        RunDurations.Breakdown(startupRunSeconds: startup, startupRunProcesses: 2, wholeSelectionSeconds: 0, wholeSelectionMutants: 0, wholeSelectionReasons: [:],
                               ownTestsSeconds: own, ownTestsMutants: 3, recheckSeconds: recheck, recheckMutants: 6, controlSeconds: control, finalBaselineSeconds: final,
                               lostProcesses: 0, otherSeconds: 0, totalSeconds: 0)
    }

    /// With several workers the parts of the time they ran side by side are shares of it, and never add up to more
    /// than the whole (two workers' 300 s of rechecks in a phase of 250 s were shown as 300 s of 250). What runs alone
    /// after them is not divided, and a dropped worker counts only while it was there.
    @Test func theBreakdownWithSeveralWorkersDoesNotExceedTheWhole() {
        let all = Self.parts(startup: 100, recheck: 300, control: 20, final: 30)
        // Everything side by side, 250 s, both workers there all the time
        let two = RunDurations.Breakdown.fitted(all, phaseSeconds: 250, parallel: (all, 250, 500, 2))
        #expect(two.totalSeconds == 280 && two.recheckSeconds == 150 && two.startupRunSeconds == 50 && two.controlSeconds == 10 && two.finalBaselineSeconds == 30)
        #expect(two.otherSeconds == 40 && two.workers == 2)
        #expect(two.line.hasPrefix("time of the mutant phase and the final baseline 4m40s (2 workers side by side: their time is divided among them): rechecks against all tests 2m30s (6)"))
        // 220 s side by side, then 60 s of mutants run alone again: those are not divided
        let serial = Self.parts(startup: 100, recheck: 300, control: 20, own: 60, final: 30)
        let after = RunDurations.Breakdown.fitted(serial, phaseSeconds: 280, parallel: (all, 220, 440, 2))
        #expect(after.ownTestsSeconds == 60 && after.recheckSeconds == 150 && after.startupRunSeconds == 50 && after.controlSeconds == 10)
        #expect(after.otherSeconds == 10 && after.totalSeconds == 310)
        // One of two workers dropped after 100 of 200 s: 300 s of worker time stand for 200 s
        let dropped = RunDurations.Breakdown.fitted(Self.parts(recheck: 270), phaseSeconds: 200, parallel: (Self.parts(recheck: 270), 200, 300, 2))
        #expect(abs(dropped.recheckSeconds - 180) < 0.001 && abs(dropped.otherSeconds - 20) < 0.001)
        // More worker time than measured: scaled down to the time side by side
        let over = RunDurations.Breakdown.fitted(all, phaseSeconds: 150, parallel: (all, 150, 300, 2))
        #expect(abs(over.startupRunSeconds + over.recheckSeconds + over.controlSeconds - 150) < 0.001 && over.otherSeconds == 0)
        // One worker: as measured
        let one = RunDurations.Breakdown.fitted(all, phaseSeconds: 500)
        #expect(one.recheckSeconds == 300 && one.otherSeconds == 80 && one.workers == nil && !one.line.contains("workers"))
    }

    /// A host that was stopped in the background makes the tool stop starting hosts (outside the shared processes,
    /// whose handling gives up on any reason), and the mutant that was on is run again, not judged: the process ended
    /// while it was on.
    @Test func aHostStoppedInTheBackgroundIsGivenUpAndItsMutantRunAgain() {
        var outcome = SharedProcess.SessionResult()
        outcome.ending = .exited
        outcome.unusable = "the app went to the background and stayed there for 10s"
        #expect(MutantExecutor.backgroundGiveUpReason(outcome) == nil)
        outcome.stoppedInBackground = true
        #expect(MutantExecutor.backgroundGiveUpReason(outcome) == "the app went to the background and stayed there for 10s")
        var events = SharedProcess.Events()
        events.begun.append(7)
        guard case .alone = SharedProcess.verdict(for: 7, events: events, ending: .exited) else {
            Issue.record("the mutant that was on is run again")
            return
        }
    }

    /// A host started by the tool whose app goes to the background and stays there is stopped after the grace time,
    /// not at the time limit of the phase (about 290 s each time on an app whose tests open a URL); an app that comes
    /// back in time is not.
    @Test func aHostThatStaysInTheBackgroundIsStoppedAfterTheGraceTime() {
        typealias State = SharedProcess.Events.AppState
        let start = Date(timeIntervalSince1970: 1000)
        var watch = SharedProcess.BackgroundWatch(grace: 10)
        let background = [State(state: "background", time: nil, test: "T.testOpensURL")]
        do { let stalled = watch.stalled([], now: start); #expect(!stalled) }
        do { let stalled = watch.stalled(background, now: start); #expect(!stalled) }
        do { let stalled = watch.stalled(background, now: start.addingTimeInterval(9)); #expect(!stalled) }
        do { let stalled = watch.stalled(background, now: start.addingTimeInterval(10)); #expect(stalled) }
        // Back to the front within the grace time, then out again: the clock starts again
        var back = SharedProcess.BackgroundWatch(grace: 10)
        let returned = background + [State(state: "foreground", time: nil, test: "T.testOpensURL")]
        do { let stalled = back.stalled(background, now: start); #expect(!stalled) }
        do { let stalled = back.stalled(returned, now: start.addingTimeInterval(5)); #expect(!stalled) }
        do { let stalled = back.stalled(returned, now: start.addingTimeInterval(60)); #expect(!stalled) }
        let again = returned + [State(state: "background", time: nil, test: "T.testOther")]
        do { let stalled = back.stalled(again, now: start.addingTimeInterval(61)); #expect(!stalled) }
        do { let stalled = back.stalled(again, now: start.addingTimeInterval(70)); #expect(!stalled) }
        do { let stalled = back.stalled(again, now: start.addingTimeInterval(71)); #expect(stalled) }
    }
}
