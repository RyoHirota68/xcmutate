import Foundation

/// How xcodebuild is invoked (the arguments passed by the user).
public struct XcodeOptions: Sendable {
    /// `-project <path>` or `-workspace <path>` (converted to an absolute path inside the work copy).
    public var container: [String]
    public var scheme: String?
    public var destination: String
    public var testPlan: String?
    /// Arguments added only to build-for-testing.
    public var extraBuildArguments: [String]
    /// Arguments added only to test-without-building.
    public var extraTestArguments: [String]
    public var onlyTesting: [String]
    public var skipTesting: [String]
    /// Build setting overrides (`KEY=VALUE`).
    public var buildSettings: [String]
    /// SwiftPM package (`--package`): runs build-for-testing in this directory, without `-project` / `-workspace`.
    public var workingDirectory: String?

    public init(container: [String], scheme: String?, destination: String, testPlan: String?,
                extraBuildArguments: [String], extraTestArguments: [String],
                onlyTesting: [String], skipTesting: [String], buildSettings: [String], workingDirectory: String? = nil) {
        self.container = container
        self.scheme = scheme
        self.destination = destination
        self.testPlan = testPlan
        self.extraBuildArguments = extraBuildArguments
        self.extraTestArguments = extraTestArguments
        self.onlyTesting = onlyTesting
        self.skipTesting = skipTesting
        self.buildSettings = buildSettings
        self.workingDirectory = workingDirectory
    }
}

struct Xcode {
    var options: XcodeOptions
    var derivedData: URL
    /// Directory name, next to `derivedData`, that `test-without-building` uses for its own logs. One per worker:
    /// two invocations must not share it.
    var testDerivedDataName = "TestDerivedData"

    func buildForTesting(resultBundle: URL, log: URL) throws -> ProcessOutcome {
        try? FileManager.default.removeItem(at: resultBundle)
        var args = ["xcodebuild", "build-for-testing"] + options.container
        if let scheme = options.scheme { args += ["-scheme", scheme] }
        args += ["-destination", options.destination]
        if let plan = options.testPlan { args += ["-testPlan", plan] }
        args += ["-derivedDataPath", derivedData.path, "-resultBundlePath", resultBundle.path]
        // Even if a target fails, continue with the rest that can be built. A single build then collects the errors of the mutants that
        // do not compile for all files and all targets at once (the same setting as Xcodebuild.swift in debugholic/litmus.
        // `-<user default>=<value>` applies only to that one xcodebuild invocation)
        args += ["-IDEBuildingContinueBuildingAfterErrors=YES"]
        // The index is not needed for running tests
        args += ["COMPILER_INDEX_STORE_ENABLE=NO"]
        args += options.extraBuildArguments + options.buildSettings
        return try Subprocess.run(args, cwd: options.workingDirectory, logPath: log.path)
    }

    /// The xctestrun created by build-for-testing (when a test plan is specified, the one containing its name).
    func xctestrun() -> URL? {
        xctestrun(since: nil).chosen
    }

    /// The `.xctestrun` file to use, and the other files it was chosen from (a scheme with several test plans
    /// produces one file per plan).
    /// - Parameter since: when the build started. Files that were last written before it come from an earlier
    ///   build (another test plan, another SDK) and are not candidates, unless nothing newer exists.
    func xctestrun(since: Date?) -> (chosen: URL?, others: [URL]) {
        let products = derivedData.appendingPathComponent("Build/Products")
        func modified(_ url: URL) -> Date { (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
        let files = ((try? FileManager.default.contentsOfDirectory(at: products, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "xctestrun" }
        var candidates = options.testPlan.map { plan in files.filter { $0.lastPathComponent.contains("_\(plan)_") } } ?? files
        if candidates.isEmpty { candidates = files }
        // A second of slack: file systems round modification times
        if let since {
            let fresh = candidates.filter { modified($0) >= since.addingTimeInterval(-1) }
            if !fresh.isEmpty { candidates = fresh }
        }
        let chosen = candidates.max { modified($0) < modified($1) }
        return (chosen, candidates.filter { $0 != chosen }.sorted { $0.lastPathComponent < $1.lastPathComponent })
    }

    func testWithoutBuilding(xctestrun: URL, environment: [String: String], resultBundle: URL, log: URL, timeout: TimeInterval?,
                             watch: LogWatch? = nil) throws -> ProcessOutcome {
        try? FileManager.default.removeItem(at: resultBundle)
        var args = ["xcodebuild", "test-without-building", "-xctestrun", xctestrun.path,
                    "-destination", options.destination, "-collect-test-diagnostics", "never",
                    "-resultBundlePath", resultBundle.path,
                    // If not specified, a small folder is added to the default DerivedData (~/Library/Developer/Xcode/DerivedData) on every run
                    "-derivedDataPath", derivedData.deletingLastPathComponent().appendingPathComponent(testDerivedDataName).path,
                    // If parallel testing is enabled in the scheme or test plan, clones of the specified simulator are launched on their own
                    "-parallel-testing-enabled", "NO"]
        args += options.onlyTesting.map { "-only-testing:\($0)" }
        args += options.skipTesting.map { "-skip-testing:\($0)" }
        args += options.extraTestArguments
        // A run that is out of time is stopped at once: its result bundle is not read (a Timeout is decided by the
        // record of the switch, which the helper flushes line by line), so there is nothing to wait for
        return try Subprocess.run(args, environment: environment, logPath: log.path, timeout: timeout, stop: .immediate, watch: watch)
    }

    /// Bundle IDs of the test host apps (to stop them on the simulator on a timeout).
    static func hostBundleIdentifiers(xctestrun: URL) -> [String] {
        guard let data = try? Data(contentsOf: xctestrun),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return [] }
        var ids: Set<String> = []
        func collect(_ target: [String: Any]) {
            for key in ["TestHostBundleIdentifier", "UITargetAppBundleIdentifier"] {
                if let id = target[key] as? String, !id.isEmpty { ids.insert(id) }
            }
        }
        if let configurations = plist["TestConfigurations"] as? [[String: Any]] {
            for configuration in configurations {
                for target in configuration["TestTargets"] as? [[String: Any]] ?? [] { collect(target) }
            }
        }
        for (_, value) in plist { if let target = value as? [String: Any] { collect(target) } }
        return ids.sorted()
    }

    /// Names of the executables of the test hosts in an `.xctestrun` file (`App` for `…/App.app`, `xctest` for the
    /// agent that hosts tests without an app): the name that NSLog and os_log put before the process ID.
    static func hostExecutableNames(xctestrun: URL) -> Set<String> {
        guard let data = try? Data(contentsOf: xctestrun),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return [] }
        var names: Set<String> = []
        func collect(_ target: [String: Any]) {
            if let path = target["TestHostPath"] as? String, !path.isEmpty {
                names.insert(URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent)
            }
        }
        if let configurations = plist["TestConfigurations"] as? [[String: Any]] {
            for configuration in configurations {
                for target in configuration["TestTargets"] as? [[String: Any]] ?? [] { collect(target) }
            }
        }
        for (_, value) in plist { if let target = value as? [String: Any] { collect(target) } }
        return names
    }

    /// Names of the test plan configurations (when the xctestrun is in the format that has configurations).
    static func testConfigurationNames(xctestrun: URL) -> [String] {
        guard let data = try? Data(contentsOf: xctestrun),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let configurations = plist["TestConfigurations"] as? [[String: Any]] else { return [] }
        return configurations.compactMap { $0["Name"] as? String }
    }

    /// The `id=<UDID>` of `-destination`.
    var simulatorUDID: String? {
        for part in options.destination.split(separator: ",") {
            let kv = part.split(separator: "=", maxSplits: 1)
            if kv.count == 2, kv[0].trimmingCharacters(in: .whitespaces) == "id" {
                return kv[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// After a timeout, stops the test host apps left on the simulator.
    func terminateHostApps(xctestrun: URL, logDirectory: URL) {
        // `id=<UDID>`, or the one simulator that `platform=iOS Simulator,name=…` names
        guard let udid = simulatorUDID ?? SimulatorCheck.simulator(forDestination: options.destination)?.udid else { return }
        for id in Self.hostBundleIdentifiers(xctestrun: xctestrun) {
            _ = try? Subprocess.capture(["xcrun", "simctl", "terminate", udid, id], timeout: 30, ignoresInterrupt: true)
        }
    }
}

/// Summary of the test results in an xcresult (`xcrun xcresulttool get test-results summary`).
public struct TestSummary: Codable, Sendable, Equatable {
    public var result: String
    public var totalTestCount: Int
    public var passedTests: Int
    public var failedTests: Int
    public var skippedTests: Int
    public var expectedFailures: Int
    public var failures: [Failure]

    public struct Failure: Codable, Sendable, Equatable {
        public var test: String
        public var message: String

        /// Whether the failure is a crash of the process that ran the test.
        public var isCrash: Bool {
            let m = message.lowercased()
            return m.contains("crash") || m.contains("unexpected exit") || m.contains("signal ") || m.contains("exited with")
        }

        /// False for an entry that stands for the process, not for a test: "<host> (<pid>) encountered an error".
        /// (The identifier of a test is `Suite/test()`, or a function name for a Swift Testing test outside a
        /// suite; neither holds a space followed by a process id in parentheses.)
        public var namesATest: Bool {
            if test.isEmpty || test == "?" { return false }
            if test.hasSuffix("encountered an error") { return false }
            return test.range(of: #" \(\d+\) "#, options: .regularExpression) == nil
        }
    }

    /// Whether it includes failures caused by a crash.
    public var hasCrash: Bool { failures.contains(where: \.isCrash) }

    /// The tests to name for a detection, and the failure to quote. A result bundle also lists failures that are
    /// not tests ("<host> (<pid>) encountered an error", for a host that ended unexpectedly): those are never
    /// named as tests. After a crash `xcodebuild` starts the host again, and tests of later suites can then fail
    /// for want of what the earlier ones had set up: for a crash only the tests that crashed are named, not those.
    public var detection: (tests: [String], quoted: Failure?) {
        let relevant = hasCrash ? failures.filter(\.isCrash) : failures
        let tests = Array(Set(relevant.filter(\.namesATest).map(\.test))).sorted()
        return (tests, relevant.first(where: \.namesATest) ?? relevant.first)
    }

    static func load(_ bundle: URL) -> TestSummary? {
        guard FileManager.default.fileExists(atPath: bundle.path),
              let result = try? Subprocess.capture(["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", bundle.path, "--compact"], timeout: 120),
              result.status == 0,
              let start = result.output.firstIndex(of: "{"),
              let data = String(result.output[start...]).data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let failures = (json["testFailures"] as? [[String: Any]] ?? []).map { f in
            Failure(test: (f["testIdentifierString"] as? String) ?? (f["testName"] as? String) ?? "?",
                    message: (f["failureText"] as? String) ?? "")
        }
        return TestSummary(
            result: json["result"] as? String ?? "unknown",
            totalTestCount: json["totalTestCount"] as? Int ?? 0,
            passedTests: json["passedTests"] as? Int ?? 0,
            failedTests: json["failedTests"] as? Int ?? 0,
            skippedTests: json["skippedTests"] as? Int ?? 0,
            expectedFailures: json["expectedFailures"] as? Int ?? 0,
            failures: failures)
    }
}

/// A `path:line:col: error: message` in the build log.
struct CompilerDiagnostic: Hashable {
    var path: String
    var line: Int
    var column: Int
    var message: String

    static func errors(inLog log: String) -> [CompilerDiagnostic] {
        var result: [CompilerDiagnostic] = []
        for line in log.split(separator: "\n") {
            guard line.hasPrefix("/"), let range = line.range(of: ": error: ") else { continue }
            let location = line[..<range.lowerBound].split(separator: ":")
            guard location.count >= 3, let l = Int(location[location.count - 2]), let c = Int(location[location.count - 1]) else { continue }
            let path = location[0..<(location.count - 2)].joined(separator: ":")
            result.append(CompilerDiagnostic(path: path, line: l, column: c, message: String(line[range.upperBound...])))
        }
        return Array(Set(result)).sorted { ($0.path, $0.line, $0.column) < ($1.path, $1.line, $1.column) }
    }
}

/// Log phrases that indicate an execution infrastructure error (a failure that is not a test result).
enum RunnerErrorPatterns {
    static let all = [
        "Test runner exited before starting test execution",
        "Failed to install or launch the test runner",
        "Unable to boot",
        "Unable to find a destination matching",
        "The test runner failed to initialize",
        "Failed to create a bundle instance",
        "Early unexpected exit, operation never finished bootstrapping",
    ]

    static func match(in log: String) -> String? {
        all.first { log.contains($0) }
    }
}
