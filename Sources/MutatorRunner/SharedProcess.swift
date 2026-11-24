import CryptoKit
import Darwin
import Foundation
import MutatorCore

/// Running several mutants in one test process (`--shared-process`).
///
/// Launching the test host is most of what a mutant costs on a simulator (about 4 of 5 seconds on the fixture). In
/// this mode `xcodebuild` launches the host once, and a driver inside it (`SharedProcessDriverSource`) switches from
/// one mutant to the next and runs the tests each time.
///
/// What a shared process is trusted with, and what goes back to a process of its own:
///
/// | Observed in the shared process | Result |
/// |---|---|
/// | Tests failed with the switch evaluated as active, and the same tests passed again right after without the mutant | Killed |
/// | Tests passed | Run again alone (a state left by earlier runs can hide a failure), unless `trustSurvivors` |
/// | The switch was evaluated before the tests started, or not equally often in two runs without mutants | Run alone |
/// | Crash, hang, a test count that differs, no evaluation as active, tests that fail again without the mutant | Run alone |
///
/// | The tests did not finish in time with the mutant on, directly after the same tests had passed without mutants | Timeout |
///
/// Before any mutant, the driver runs the tests twice without mutants. Both runs must pass and must run as many
/// tests as the baseline did under `xcodebuild`; otherwise the mode is given up for the run and every mutant is run
/// alone, as without the option. The two runs are made once per unit, destination and way of starting the host
/// (`Gate`): a later process (after a crash or a hang) takes what they showed from the first one and runs, in their
/// place, the tests of its first mutant once without mutants.
enum SharedProcess {
    /// The test target that the shared process serves, read from the `.xctestrun` file of the build.
    struct Target: Sendable, Equatable {
        var blueprintName: String
        var moduleName: String
        /// The project's test bundle among the build products (absolute path).
        var bundlePath: String
        /// Tests to run (`Class`, `Class/method`); empty: all of the target.
        var only: [String]
        var skip: [String]
        /// Name of the test-plan configuration (format version 2), if any.
        var configurationName: String?
        /// The test host with its placeholders written out: the app that hosts the tests, or the `xctest` agent.
        var hostPath = ""
        var hostBundleIdentifier: String?
        var isAppHosted = false
        /// Arguments of the test process (a test-plan configuration's language and region arrive this way).
        var commandLineArguments: [String] = []
        /// Environment of the test process as `xcodebuild` sets it (`EnvironmentVariables` and
        /// `TestingEnvironmentVariables` of the entry, the second winning), placeholders not yet written out.
        var environment: [String: String] = [:]

        /// `Configuration / Target`, or the target alone when the plan has no configurations.
        var label: String { configurationName.map { "\($0) / \(blueprintName)" } ?? blueprintName }
    }

    struct Unavailable: Error, CustomStringConvertible, Equatable {
        var description: String
        init(_ description: String) { self.description = description }
    }

    // MARK: Which targets

    /// The units that the selection runs: every selected unit-test target in every selected test-plan
    /// configuration, in the order of the `.xctestrun` file. One shared process serves one unit, because a unit is
    /// what `xcodebuild` gives a process of its own (a configuration can change language and region, a target has
    /// its own bundle and often its own host). A selection that includes a UI test target is not served.
    static func units(xctestrun: URL, options: XcodeOptions) -> Result<[Target], Unavailable> {
        guard let data = try? Data(contentsOf: xctestrun),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return .failure(Unavailable("the .xctestrun file could not be read"))
        }
        return units(plist: plist, productsDirectory: xctestrun.deletingLastPathComponent().path, options: options)
    }

    static func units(plist: [String: Any], productsDirectory: String, options: XcodeOptions) -> Result<[Target], Unavailable> {
        var groups: [(configuration: String?, targets: [[String: Any]])] = []
        if let configurations = plist["TestConfigurations"] as? [[String: Any]] {
            var chosen = configurations
            let requested = requestedConfigurations(options.extraTestArguments)
            if !requested.isEmpty { chosen = configurations.filter { requested.contains($0["Name"] as? String ?? "") } }
            guard !chosen.isEmpty else { return .failure(Unavailable("no test-plan configuration is selected")) }
            groups = chosen.map { ($0["Name"] as? String, $0["TestTargets"] as? [[String: Any]] ?? []) }
        } else {
            groups = [(nil, plist.keys.sorted().filter { $0 != "__xctestrun_metadata__" }.compactMap { plist[$0] as? [String: Any] })]
        }
        func name(_ target: [String: Any]) -> String { target["BlueprintName"] as? String ?? "" }
        let onlyTargets = Set(options.onlyTesting.map { String($0.split(separator: "/").first ?? "") })
        let skippedTargets = Set(options.skipTesting.filter { !$0.contains("/") })
        var result: [Target] = []
        for group in groups {
            let selected = group.targets.filter { (onlyTargets.isEmpty || onlyTargets.contains(name($0))) && !skippedTargets.contains(name($0)) }
            guard !selected.isEmpty else { return .failure(Unavailable("the selection covers no test target")) }
            for target in selected {
                guard target["IsUITestBundle"] as? Bool != true else {
                    return .failure(Unavailable("\(name(target)) is a UI test target; leave it out with --only-testing or --skip-testing"))
                }
                guard let bundle = target["TestBundlePath"] as? String else {
                    return .failure(Unavailable("the .xctestrun file names no test bundle for \(name(target))"))
                }
                let host = (target["TestHostPath"] as? String ?? "").replacingOccurrences(of: "__TESTROOT__", with: productsDirectory)
                let bundlePath = bundle.replacingOccurrences(of: "__TESTHOST__", with: host).replacingOccurrences(of: "__TESTROOT__", with: productsDirectory)

                func strip(_ identifiers: [String]) -> [String]? {
                    var result: [String] = []
                    for identifier in identifiers {
                        let parts = identifier.split(separator: "/", maxSplits: 1).map(String.init)
                        guard parts.first == name(target) else { continue }
                        // The target alone: everything in it
                        guard parts.count == 2 else { return nil }
                        result.append(parts[1])
                    }
                    return result
                }
                var only = strip(options.onlyTesting) ?? []
                if only.isEmpty { only = target["OnlyTestIdentifiers"] as? [String] ?? [] }
                let skip = (strip(options.skipTesting.filter { $0.contains("/") }) ?? []) + (target["SkipTestIdentifiers"] as? [String] ?? [])
                var environment: [String: String] = [:]
                for key in ["EnvironmentVariables", "TestingEnvironmentVariables"] {
                    for (variable, value) in target[key] as? [String: Any] ?? [:] { environment[variable] = value as? String ?? "\(value)" }
                }
                var unit = Target(blueprintName: name(target), moduleName: target["ProductModuleName"] as? String ?? name(target),
                                  bundlePath: bundlePath, only: only, skip: skip, configurationName: group.configuration)
                unit.hostPath = host
                unit.hostBundleIdentifier = target["TestHostBundleIdentifier"] as? String
                unit.isAppHosted = target["IsAppHostedTestBundle"] as? Bool ?? (host.hasSuffix(".app"))
                unit.commandLineArguments = Self.hostArguments(target["CommandLineArguments"] as? [String] ?? [],
                                                               language: target["TestLanguage"] as? String, region: target["TestRegion"] as? String)
                unit.environment = environment
                result.append(unit)
            }
        }
        return .success(result)
    }

    /// The names given with `-only-test-configuration <name>` among extra `test-without-building` arguments.
    static func requestedConfigurations(_ arguments: [String]) -> [String] {
        var names: [String] = []
        var index = 0
        while index < arguments.count {
            if arguments[index] == "-only-test-configuration", index + 1 < arguments.count {
                names.append(arguments[index + 1])
                index += 1
            } else if arguments[index].hasPrefix("-only-test-configuration:") {
                names.append(String(arguments[index].dropFirst("-only-test-configuration:".count)))
            }
            index += 1
        }
        return names
    }

    // MARK: The driver bundle

    /// Platform and minimum OS version of a Mach-O file, from `vtool -show-build`.
    static func buildVersion(vtoolOutput: String) -> (platform: String, minimumOS: String)? {
        var platform: String?
        var minimumOS: String?
        for line in vtoolOutput.split(separator: "\n") {
            let words = line.split(separator: " ")
            guard words.count >= 2 else { continue }
            if words[0] == "platform", platform == nil { platform = String(words[1]) }
            if words[0] == "minos", minimumOS == nil { minimumOS = String(words[1]) }
        }
        guard let platform, let minimumOS else { return nil }
        return (platform, minimumOS)
    }

    /// SDK name and target triple for compiling the driver so that it loads next to a test bundle of this platform.
    static func toolchainTarget(platform: String, minimumOS: String, architecture: String) -> (sdk: String, triple: String, isMacOS: Bool)? {
        switch platform {
        case "IOSSIMULATOR": ("iphonesimulator", "\(architecture)-apple-ios\(minimumOS)-simulator", false)
        case "MACOS": ("macosx", "\(architecture)-apple-macos\(minimumOS)", true)
        default: nil
        }
    }

    /// The compiled driver for one platform and deployment target.
    struct Driver: Sendable, Equatable {
        /// The test bundle that `xcodebuild` or the `xctest` agent runs.
        var bundle: URL
        /// The same code as a dynamic library, for a host app that the tool launches itself.
        var library: URL
        var isMacOS: Bool
    }

    /// Compiles the driver under `directory` (reused when the source and the target are unchanged): as a test bundle,
    /// and as a dynamic library whose initializer starts the session in an app.
    static func buildDriver(for target: Target, in directory: URL, log: URL) throws -> Driver {
        guard let binary = Bundle(path: target.bundlePath)?.executablePath else {
            throw Unavailable("the test bundle \(target.bundlePath) has no executable")
        }
        guard let vtool = try? Subprocess.capture(["/usr/bin/xcrun", "vtool", "-show-build", binary], timeout: 60), vtool.status == 0,
              let version = buildVersion(vtoolOutput: vtool.output) else {
            throw Unavailable("the platform of \(binary) could not be read")
        }
        var system = utsname()
        uname(&system)
        let architecture = withUnsafeBytes(of: &system.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        guard let toolchain = toolchainTarget(platform: version.platform, minimumOS: version.minimumOS, architecture: architecture) else {
            throw Unavailable("test bundles for the platform \(version.platform) are not supported")
        }
        func xcrun(_ arguments: [String]) throws -> String {
            guard let result = try? Subprocess.capture(["/usr/bin/xcrun", "--sdk", toolchain.sdk] + arguments, timeout: 120), result.status == 0 else {
                throw Unavailable("xcrun --sdk \(toolchain.sdk) \(arguments.joined(separator: " ")) failed")
            }
            return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let sdkPath = try xcrun(["--show-sdk-path"])
        let platformPath = try xcrun(["--show-sdk-platform-path"])

        let name = SharedProcessDriverSource.className
        let source = SharedProcessDriverSource.source
        let digest = SHA256.hash(data: Data((source + toolchain.triple + sdkPath).utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        let home = directory.appendingPathComponent("driver-\(digest)")
        let bundle = home.appendingPathComponent("\(name).xctest")
        let contents = toolchain.isMacOS ? bundle.appendingPathComponent("Contents") : bundle
        let executable = (toolchain.isMacOS ? contents.appendingPathComponent("MacOS") : contents).appendingPathComponent(name)
        let library = home.appendingPathComponent("lib\(name).dylib")
        let marker = home.appendingPathComponent("built")
        let driver = Driver(bundle: bundle, library: library, isMacOS: toolchain.isMacOS)
        let fm = FileManager.default
        if fm.fileExists(atPath: marker.path), fm.fileExists(atPath: executable.path), fm.fileExists(atPath: library.path) { return driver }

        try? fm.removeItem(at: home)
        try fm.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        let sourceFile = home.appendingPathComponent("Driver.swift")
        try source.write(to: sourceFile, atomically: true, encoding: .utf8)
        let info: [String: Any] = [
            "CFBundleExecutable": name, "CFBundleIdentifier": "dev.xcmutate.shared-process", "CFBundleName": name,
            "CFBundlePackageType": "BNDL", "CFBundleInfoDictionaryVersion": "6.0", "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0",
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        let common = ["/usr/bin/xcrun", "--sdk", toolchain.sdk, "swiftc", "-sdk", sdkPath, "-target", toolchain.triple, "-swift-version", "5",
                      "-Onone", "-suppress-warnings",
                      "-F", platformPath + "/Developer/Library/Frameworks", "-I", platformPath + "/Developer/usr/lib", "-L", platformPath + "/Developer/usr/lib",
                      "-module-name", name, "-emit-library"]
        let compile = try Subprocess.run(common + ["-Xlinker", "-bundle", "-o", executable.path, sourceFile.path], logPath: log.path, timeout: 600)
        guard compile.status == 0 else { throw Unavailable("the driver did not compile (log: \(log.path))") }
        let libraryLog = log.deletingPathExtension().appendingPathExtension("library.log")
        let link = try Subprocess.run(common + ["-Xlinker", "-init", "-Xlinker", "_" + SharedProcessDriverSource.directEntryPoint, "-o", library.path, sourceFile.path],
                                      logPath: libraryLog.path, timeout: 600)
        guard link.status == 0 else { throw Unavailable("the driver did not compile as a library (log: \(libraryLog.path))") }
        _ = try? Subprocess.capture(["/usr/bin/codesign", "-s", "-", "--force", bundle.path], timeout: 120)
        _ = try? Subprocess.capture(["/usr/bin/codesign", "-s", "-", "--force", library.path], timeout: 120)
        fm.createFile(atPath: marker.path, contents: nil)
        return driver
    }

    // MARK: Starting the test host without xcodebuild

    /// How the tool starts the test host of a unit by itself.
    ///
    /// `xcodebuild test-without-building` spends one to two seconds before the test host starts, installs the host
    /// app again and attaches a test session. None of that is needed when the driver runs the tests and reports the
    /// results itself, so the tool can start the host directly:
    ///
    /// | Host | Destination | Command |
    /// |---|---|---|
    /// | `xctest` agent (no host app) | macOS | the agent, with the driver bundle as its argument |
    /// | `xctest` agent | simulator | `simctl spawn <udid>` + the same |
    /// | app | simulator | `simctl launch --console --terminate-running-process <udid> <bundle id>`, the driver library inserted |
    /// | app | macOS | the app's executable, the driver library inserted |
    ///
    /// The process gets the environment and the arguments that the `.xctestrun` file holds for the unit. It does not
    /// get a test session of Xcode, so the first process started this way in a run is a control: the tests must pass
    /// in it, as many as in the baseline (`MutantExecutor`).
    struct DirectLaunch: Equatable {
        var arguments: [String]
        var environment: [String: String]
        /// Bundle identifier to terminate on the simulator when the process cannot be stopped by its process ID.
        var simulatorApp: (udid: String, bundleIdentifier: String)?

        static func == (a: DirectLaunch, b: DirectLaunch) -> Bool {
            a.arguments == b.arguments && a.environment == b.environment && a.simulatorApp?.udid == b.simulatorApp?.udid
                && a.simulatorApp?.bundleIdentifier == b.simulatorApp?.bundleIdentifier
        }
    }

    /// Paths that the placeholders of an `.xctestrun` file stand for.
    struct Placeholders: Sendable, Equatable {
        var developerDirectory: String
        var productsDirectory: String
        var derivedData: String

        func expand(_ text: String, host: String) -> String {
            var result = text
            for (name, value) in [("__TESTHOST__", host), ("__TESTROOT__", productsDirectory), ("__DERIVEDDATA__", derivedData),
                                  ("__PLATFORMS__", developerDirectory + "/Platforms"),
                                  ("__SHAREDFRAMEWORKS__", URL(fileURLWithPath: developerDirectory).deletingLastPathComponent().appendingPathComponent("SharedFrameworks").path),
                                  ("__DEVELOPERUSRLIB__", developerDirectory + "/usr/lib")] {
                result = result.replacingOccurrences(of: name, with: value)
            }
            return result
        }

        /// True if a placeholder that is not known is left in the text (then nothing is launched directly).
        static func hasUnknown(_ text: String) -> Bool {
            text.range(of: "__[A-Z]+__", options: .regularExpression) != nil
        }
    }

    /// The command that starts the test host of `unit` with the driver, or the reason why the tool cannot start it.
    /// - Parameter session: environment of the driver and the helper (session directory, shared region, active mutant).
    static func directLaunch(unit: Target, driver: Driver, simulatorUDID: String?, placeholders: Placeholders,
                             session: [String: String]) -> Result<DirectLaunch, Unavailable> {
        var environment: [String: String] = [:]
        for (key, value) in unit.environment {
            let expanded = placeholders.expand(value, host: unit.hostPath)
            guard !Placeholders.hasUnknown(expanded) else {
                return .failure(Unavailable("the environment of \(unit.blueprintName) in the .xctestrun file has a placeholder that is not known (\(key)=\(value))"))
            }
            environment[key] = expanded
        }
        let host = placeholders.expand(unit.hostPath, host: "")
        guard !host.isEmpty, !Placeholders.hasUnknown(host) else {
            return .failure(Unavailable("the test host of \(unit.blueprintName) is not known (\(unit.hostPath))"))
        }
        let arguments = unit.commandLineArguments.map { placeholders.expand($0, host: host) }
        if !driver.isMacOS, simulatorUDID == nil {
            return .failure(Unavailable("the destination does not name a simulator by id"))
        }
        // XCTest's own library for injecting a bundle into an app is replaced by the driver library
        var inserted = (environment["DYLD_INSERT_LIBRARIES"] ?? "").split(separator: ":").map(String.init)
            .filter { !$0.contains("libXCTestBundleInject") && !$0.isEmpty }
        for (key, value) in session { environment[key] = value }
        // Products built with coverage write `default.profraw` into the current directory unless told where to
        // write; `xcodebuild` sets this variable too. The current directory is the user's, so nothing may land there.
        if let directory = session[SharedProcessDriverSource.sessionEnvironmentVariable] {
            environment["LLVM_PROFILE_FILE"] = directory + "/host.profraw"
        }

        var command: [String]
        var simulatorApp: (udid: String, bundleIdentifier: String)?
        if unit.isAppHosted {
            inserted.insert(driver.library.path, at: 0)
            // Apps commonly look at these to see that they are hosting tests
            environment["XCTestBundlePath"] = unit.bundlePath
            environment["XCTestConfigurationFilePath"] = session[SharedProcessDriverSource.sessionEnvironmentVariable].map { $0 + "/none.xctestconfiguration" } ?? ""
            environment["XCTestSessionIdentifier"] = UUID().uuidString
            if driver.isMacOS {
                guard let executable = Bundle(path: host)?.executablePath else {
                    return .failure(Unavailable("the host app \(host) has no executable"))
                }
                command = [executable] + arguments
            } else {
                guard let udid = simulatorUDID, let identifier = unit.hostBundleIdentifier, !identifier.isEmpty else {
                    return .failure(Unavailable("the .xctestrun file does not name the bundle identifier of the host app"))
                }
                command = ["/usr/bin/xcrun", "simctl", "launch", "--console", "--terminate-running-process", udid, identifier] + arguments
                simulatorApp = (udid, identifier)
            }
        } else {
            let test = "\(SharedProcessDriverSource.className)/\(SharedProcessDriverSource.testName)"
            command = [host, "-XCTest", test, driver.bundle.path] + arguments
            if !driver.isMacOS, let udid = simulatorUDID { command = ["/usr/bin/xcrun", "simctl", "spawn", udid] + command }
        }
        if inserted.isEmpty { environment["DYLD_INSERT_LIBRARIES"] = nil } else { environment["DYLD_INSERT_LIBRARIES"] = inserted.joined(separator: ":") }
        if !driver.isMacOS {
            // `simctl` hands the variables with this prefix to the process it starts
            environment = Dictionary(uniqueKeysWithValues: environment.map { ("SIMCTL_CHILD_" + $0.key, $0.value) })
        }
        return .success(DirectLaunch(arguments: command, environment: environment, simulatorApp: simulatorApp))
    }

    /// Writes a copy of the `.xctestrun` file that runs only the driver, in the test host of `target`.
    static func writeXctestrun(original: URL, target: Target, driverBundle: URL, environment: [String: String], to destination: URL) throws {
        let data = try Data(contentsOf: original)
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw Unavailable("the .xctestrun file could not be read")
        }
        let rewritten = sessionPlist(plist, productsDirectory: original.deletingLastPathComponent().path, target: target,
                                     driverBundle: driverBundle.path, environment: environment)
        try PropertyListSerialization.data(fromPropertyList: rewritten, format: .xml, options: 0).write(to: destination)
    }

    static func sessionPlist(_ plist: [String: Any], productsDirectory: String, target: Target, driverBundle: String,
                             environment: [String: String]) -> [String: Any] {
        // The copy lives outside the build products, so `__TESTROOT__` is written out.
        func absolute(_ value: Any) -> Any {
            if let text = value as? String { return text.replacingOccurrences(of: "__TESTROOT__", with: productsDirectory) }
            if let list = value as? [Any] { return list.map(absolute) }
            if let dictionary = value as? [String: Any] { return dictionary.mapValues(absolute) }
            return value
        }
        func driver(_ original: [String: Any]) -> [String: Any] {
            var entry = original
            entry["TestBundlePath"] = driverBundle
            entry["OnlyTestIdentifiers"] = ["\(SharedProcessDriverSource.className)/\(SharedProcessDriverSource.testName)"]
            entry["SkipTestIdentifiers"] = nil
            var variables = entry["EnvironmentVariables"] as? [String: Any] ?? [:]
            for (key, value) in environment { variables[key] = value }
            entry["EnvironmentVariables"] = variables
            return entry
        }
        var result: [String: Any] = [:]
        if let metadata = plist["__xctestrun_metadata__"] { result["__xctestrun_metadata__"] = metadata }
        if let configurations = plist["TestConfigurations"] as? [[String: Any]] {
            result["TestConfigurations"] = configurations
                .filter { $0["Name"] as? String == target.configurationName }
                .map { configuration -> [String: Any] in
                    var copy = configuration
                    copy["TestTargets"] = (configuration["TestTargets"] as? [[String: Any]] ?? [])
                        .filter { $0["BlueprintName"] as? String == target.blueprintName }.map(driver)
                    return copy
                }
            for (key, value) in plist where key != "TestConfigurations" && key != "__xctestrun_metadata__" { result[key] = value }
        } else {
            for (key, value) in plist {
                guard let entry = value as? [String: Any], entry["BlueprintName"] as? String == target.blueprintName else { continue }
                result[key] = driver(entry)
            }
        }
        return absolute(result) as? [String: Any] ?? result
    }

    // MARK: What the driver reported

    /// The events of one process, as written by the driver.
    struct Events: Equatable {
        struct Control: Equatable {
            var status: String
            var tests: Int
            var seconds: Double
            /// The tests that failed in this run without mutants (at most 20 are reported).
            var failed: [String] = []
        }

        struct End: Equatable {
            var status: String
            var activations: Int
            var tests: Int
            var seconds: Double
            var failed: [String]
        }

        var processID: Int32?
        var controls: [Int: Control] = [:]
        var skipped: [Int: String] = [:]
        var begun: [Int] = []
        var ended: [Int: End] = [:]
        var checks: [Int: String] = [:]
        /// Plan gate `known`: the driver does not make the two runs without mutants, and has said that it is ready.
        var ready = false
        /// The driver has written `classes.txt`.
        var classesWritten = false
        /// Plan gate `known`: the run of the first mutant's tests without mutants, before the mutant (mutant → status).
        var pre: [Int: String] = [:]
        /// Mutants whose run began directly after the same tests had passed without mutants in this process.
        var cleanAtBegin: Set<Int> = []
        /// Mutants whose failing run came directly after a passing run of the same tests without mutants.
        var direct: Set<Int> = []
        /// The second run of a mutant whose first failing run did not come directly after such a run.
        var again: [Int: End] = [:]
        var checks2: [Int: String] = [:]
        /// Mutants the driver is done with.
        var settled: Set<Int> = []
        /// Plan mode `single`: the one run of the tests.
        var single: End?
        var stop: String?
        var done = false
        var relaunched = false

        /// The mutant whose runs (with the mutant on, and the checks without it) have started and not finished.
        var current: Int? {
            guard let last = begun.last else { return nil }
            return settled.contains(last) ? nil : last
        }

        var controlsPassed: Bool { controls[1]?.status == "ok" && controls[2]?.status == "ok" }

        /// The driver is past the start of the process: the two runs without mutants passed, or were not due.
        var gatePassed: Bool { controlsPassed || ready }

        mutating func consume(_ line: String) {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            let words = fields[0].split(separator: " ").map(String.init)
            guard let kind = words.first else { return }
            switch kind {
            case "HELLO":
                if words.count > 1 { processID = Int32(words[1]) }
            case "CONTROL":
                if words.count >= 5, let index = Int(words[1]), let tests = Int(words[3]), let seconds = Double(words[4]) {
                    controls[index] = Control(status: words[2], tests: tests, seconds: seconds, failed: Array(fields.dropFirst()))
                }
            case "SKIP":
                if words.count >= 3, let id = Int(words[1]) { skipped[id] = words[2] }
            case "BEGIN":
                if words.count >= 2, let id = Int(words[1]) {
                    begun.append(id)
                    if words.count >= 3, words[2] == "1" { cleanAtBegin.insert(id) }
                }
            case "READY":
                ready = true
            case "CLASSES":
                classesWritten = true
            case "PRE":
                if words.count >= 3, let id = Int(words[1]) { pre[id] = words[2] }
            case "END":
                if words.count >= 6, let id = Int(words[1]), let activations = Int(words[3]), let tests = Int(words[4]), let seconds = Double(words[5]) {
                    ended[id] = End(status: words[2], activations: activations, tests: tests, seconds: seconds, failed: Array(fields.dropFirst()))
                }
            case "CHECK":
                if words.count >= 3, let id = Int(words[1]) { checks[id] = words[2] }
            case "CHECK2":
                if words.count >= 3, let id = Int(words[1]) { checks2[id] = words[2] }
            case "DIRECT":
                if words.count >= 2, let id = Int(words[1]) { direct.insert(id) }
            case "AGAIN":
                if words.count >= 6, let id = Int(words[1]), let activations = Int(words[3]), let tests = Int(words[4]), let seconds = Double(words[5]) {
                    again[id] = End(status: words[2], activations: activations, tests: tests, seconds: seconds, failed: Array(fields.dropFirst()))
                }
            case "SETTLED":
                if words.count >= 2, let id = Int(words[1]) { settled.insert(id) }
            case "SINGLE":
                if words.count >= 4, let tests = Int(words[2]), let seconds = Double(words[3]) {
                    single = End(status: words[1], activations: 0, tests: tests, seconds: seconds, failed: Array(fields.dropFirst()))
                }
            case "STOP":
                stop = words.dropFirst().joined(separator: " ")
            case "DONE":
                done = true
            case "RELAUNCH":
                relaunched = true
            default:
                break
            }
        }
    }

    /// What the shared process says about one mutant.
    enum Verdict: Equatable {
        /// Tests failed with the mutant on, and passed again without it.
        case killed(failed: [String], tests: Int, seconds: Double)
        /// Tests passed with the switch evaluated as active.
        case survived(tests: Int, seconds: Double)
        /// The tests of this process did not evaluate the switch in two runs without mutants. With one unit that is a
        /// contradiction with the baseline and the mutant is run alone; with several units it is what is expected of
        /// the units whose tests do not touch the code.
        case unreached
        /// The tests did not finish in `limit` seconds with the mutant on, directly after the same tests had passed
        /// without mutants in the same process, and the switch had been evaluated as active.
        case timedOut(seconds: Double, limit: Double)
        /// Cannot be judged in a shared process; the text says why.
        case alone(String)
        /// The process ended before this mutant's turn.
        case notRun
    }

    enum Ending: Equatable {
        case done
        case exited
        case timedOut
        case interrupted
    }

    /// What the shared region said when a process ran out of time: the mutant that was on, and how often its switch
    /// had been evaluated as active in the run that did not end.
    struct Hang: Equatable {
        var id: Int
        var activations: Int
        var seconds: Double
        var limit: Double
    }

    /// Whether a run that did not end in time is the mutant's doing as it stands: the mutant was on and had been
    /// evaluated, and the same tests had passed without mutants in this process directly before (so that nothing but
    /// the mutant stands between a run that ended and one that did not). A process of its own can add nothing to that.
    static func hangIsFinal(_ id: Int, events: Events, ending: Ending, hang: Hang?) -> Bool {
        guard ending == .timedOut, let hang, hang.id == id, hang.activations > 0 else { return false }
        return events.current == id && events.ended[id] == nil && events.cleanAtBegin.contains(id)
    }

    /// A run with the mutant on did not end in time, but other runs stood between it and the last passing run without
    /// mutants: the mutant is put first in the next process, where its tests are run without mutants right before it.
    static func hangNeedsCleanRun(_ id: Int, events: Events, ending: Ending, hang: Hang?) -> Bool {
        guard ending == .timedOut, let hang, hang.id == id, hang.activations > 0 else { return false }
        return events.current == id && events.ended[id] == nil && !events.cleanAtBegin.contains(id)
    }

    static func verdict(for id: Int, events: Events, ending: Ending, confirmation: KillConfirmation = .auto, hang: Hang? = nil) -> Verdict {
        if let reason = events.skipped[id] {
            switch reason {
            case "launch": return .alone("its switch is evaluated before the tests start")
            case "uneven": return .alone("its switch was not evaluated equally often in two runs of the tests without mutants (code that runs once per process, or tests that vary)")
            default: return .unreached
            }
        }
        guard let end = events.ended[id] else {
            guard events.begun.contains(id) else { return .notRun }
            if hangIsFinal(id, events: events, ending: ending, hang: hang), let hang { return .timedOut(seconds: hang.seconds, limit: hang.limit) }
            return .alone(ending == .timedOut ? "the tests did not finish in time in the shared process" : "the shared process ended while this mutant was on")
        }
        // The driver says when it is done with a mutant; until then nothing it reported about the mutant is final
        guard events.settled.contains(id) else {
            if events.stop == "dirty" || ending != .done {
                return .alone(events.stop == "dirty" ? "after this mutant failed, the tests did not pass again without it in the shared process"
                              : ending == .timedOut ? "the tests did not finish in time in the shared process" : "the shared process ended while this mutant was on")
            }
            return .alone("the shared process did not finish with this mutant")
        }
        switch end.status {
        case "pass":
            return end.activations > 0 ? .survived(tests: end.tests, seconds: end.seconds)
                : .alone("the tests passed in the shared process without the switch being evaluated as active")
        case "fail":
            guard end.activations > 0 else { return .alone("the tests failed in the shared process without the switch being evaluated as active") }
            guard events.checks[id] == "ok" else { return .alone("after this mutant failed, the tests did not pass again without it in the shared process") }
            if events.direct.contains(id) || confirmation == .none {
                return .killed(failed: end.failed, tests: end.tests, seconds: end.seconds)
            }
            // The failing run came after another mutant's run: it counts only if the mutant failed the tests again
            // right after they had passed without mutants
            guard let again = events.again[id] else { return .alone("the failing run in the shared process was not confirmed") }
            switch again.status {
            case "fail":
                guard again.activations > 0, events.checks2[id] == "ok" else {
                    return .alone("after this mutant failed a second time, the tests did not pass again without it in the shared process")
                }
                return .killed(failed: again.failed, tests: again.tests, seconds: end.seconds + again.seconds)
            case "pass":
                return .alone("it failed once in the shared process and passed when run again right after the tests had passed without mutants: the first failure came from state left by an earlier mutant")
            default:
                return .alone("the second run in the shared process was incomplete or ran a different number of tests")
            }
        default:
            return .alone("the run in the shared process was incomplete or ran a different number of tests")
        }
    }

    // MARK: One process

    struct Entry: Encodable, Sendable {
        var id: Int
        var only: [String]?
        var tests: Int?
    }

    private struct Plan: Encodable {
        var bundlePath: String
        var bundleName: String
        var sharedPath: String
        var moduleName: String
        var only: [String]
        var skip: [String]
        var mutants: [Entry]
        var mode: String?
        var single: Entry?
        var confirm: String?
        var gate: String?
        var controlTests: Int?
        var stopAtFirstFailure: Bool?
    }

    /// The two runs without mutants at the start of a shared process.
    enum Gate: Equatable, Sendable {
        /// This process makes them.
        case full
        /// An earlier process of the same unit made them on this destination: the number of tests of a run of the
        /// whole selection, and the seconds the longer of the two runs took.
        case known(tests: Int, seconds: Double)
    }

    /// What the two runs without mutants showed about the switches (`classes.txt` of the driver).
    struct Classes: Equatable, Sendable {
        /// Evaluated before the tests started.
        var launch: Set<Int> = []
        /// Evaluated more or less often in the first run than in the second.
        var uneven: Set<Int> = []
        /// Evaluated equally often in both runs, at least once.
        var even: Set<Int> = []

        static func parse(_ text: String) -> Classes {
            var result = Classes()
            for line in text.split(separator: "\n") {
                let words = line.split(separator: " ")
                let ids = Set(words.dropFirst().compactMap { Int($0) })
                switch words.first {
                case "launch": result.launch = ids
                case "uneven": result.uneven = ids
                case "even": result.even = ids
                default: break
                }
            }
            return result
        }

        /// Takes in what another process of the same unit showed. Where two processes disagree, the switch is not
        /// treated as evaluated equally often.
        mutating func merge(_ other: Classes) {
            launch.formUnion(other.launch)
            uneven.formUnion(other.uneven)
            even = even.union(other.even).subtracting(launch).subtracting(uneven)
        }

        /// Why a mutant is not run in a shared process, as the driver would say it (`SKIP`); nil if it is run there.
        func skipReason(_ id: Int) -> String? {
            if launch.contains(id) { return "launch" }
            if uneven.contains(id) { return "uneven" }
            return even.contains(id) ? nil : "unreached"
        }
    }

    /// One unit with its compiled driver.
    struct Unit: Sendable {
        var target: Target
        var driver: Driver
    }

    struct Setup: Sendable {
        /// The units in the order in which `xcodebuild` runs them.
        var units: [Unit]
        var originalXctestrun: URL
        /// Number of switch IDs (the counters of the shared region).
        var switchCount: Int
        /// Number of tests the baseline ran under xcodebuild. The targets of one configuration must run as many
        /// together (a test plan with several configurations counts each test once).
        var expectedTests: Int
        /// Seconds allowed until the driver reports, and for each of the two runs without mutants.
        var launchTimeout: Double
        var timeoutFactor: Double
        var timeoutConstant: Double
        var placeholders: Placeholders
        /// False: every process is started by `xcodebuild` (`--no-direct-launch`).
        var directLaunch = true
        /// The environment variables of this run's embedding.
        var names = Instrumenter.EnvironmentNames()
        /// Which failing runs the driver repeats (`--confirm-kills`).
        var confirmation = KillConfirmation.auto

        /// Indices of the units of each configuration.
        var configurations: [[Int]] {
            var order: [String?] = []
            var groups: [String?: [Int]] = [:]
            for (index, unit) in units.enumerated() {
                if groups[unit.target.configurationName] == nil { order.append(unit.target.configurationName) }
                groups[unit.target.configurationName, default: []].append(index)
            }
            return order.compactMap { groups[$0] }
        }

        /// Whether the counts of the first run without mutants, as far as they are known, agree with the baseline:
        /// the units of each configuration whose counts are all known must add up to `expectedTests`.
        func countsAgree(_ counts: [Int: Int]) -> Bool {
            for group in configurations {
                let known = group.compactMap { counts[$0] }
                if known.count == group.count, known.reduce(0, +) != expectedTests { return false }
            }
            return true
        }
    }

    /// What one process is for.
    enum Mode {
        /// Several mutants, switched through the shared region.
        case session([Entry])
        /// One run of the tests in a new process (`only`, `tests` of the entry), with the mutant of `active` switched
        /// on through the environment from the start, or with none (a control).
        case single(Entry, active: Int?, trace: URL?)
    }

    enum Launcher: Hashable, Sendable {
        case xcodebuild
        /// Started by the tool itself (`DirectLaunch`).
        case direct
    }

    struct SessionResult {
        var events = Events()
        var ending = Ending.exited
        /// Set when the mode cannot be used at all for this run.
        var unusable: String?
        var duration: Double = 0
        var log: String = ""
        /// Set when the process ran out of time while a mutant was on.
        var hang: Hang?
        /// `Gate.full`: what the two runs without mutants showed about the switches.
        var classes: Classes?
        /// Exit code of the process that the tool started (`xcodebuild`, `simctl`, the host), if it ended by itself.
        var exitCode: Int32?
        /// What the driver was doing when the process ended or ran out of time (`launch`, `control 1`, …).
        var lastPhase = ""
    }

    /// The command and the environment of a host that the tool starts itself. Values are written only for the
    /// variables that the tool sets or that decide what is loaded; of the others (the project's own, from the scheme
    /// or the test plan) only the names, because they can hold secrets.
    static func launchDescription(arguments: [String], environment: [String: String], unit: Target) -> String {
        var lines = ["Test host started by \(ToolInfo.name) \(ToolInfo.version) without xcodebuild", "",
                     "unit: \(unit.label)", "host: \(unit.hostPath)\(unit.isAppHosted ? " (app)" : " (no host app)")",
                     "test bundle: \(unit.bundlePath)", "", "command:"]
        lines += arguments.map { "  " + $0 }
        lines += ["", "environment (values shown for the variables of the tool, of XCTest and of the dynamic loader):"]
        for name in environment.keys.sorted() {
            let plain = name.hasPrefix("SIMCTL_CHILD_") ? String(name.dropFirst("SIMCTL_CHILD_".count)) : name
            let shown = plain.hasPrefix(ToolNaming.environmentPrefix) || plain.hasPrefix("DYLD_") || plain.hasPrefix("XCTest") || plain.hasPrefix("XCInject")
                || plain == "LLVM_PROFILE_FILE" || plain.hasPrefix("__XC") || plain.hasPrefix("__XPC_DYLD")
            lines.append("  " + name + (shown ? "=" + (environment[name] ?? "") : ""))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// How the process ended, and the crash reports written for the host since it was started.
    static func endDescription(_ result: SessionResult, unit: Target, since start: Date) -> String {
        let events = result.events
        var lines = ["", "result:",
                     "  ended: \(result.ending) after \(String(format: "%.1f", result.duration))s, while the driver was at: \(result.lastPhase.isEmpty ? "launch" : result.lastPhase)",
                     "  process started by the tool: \(exitDescription(result.exitCode, viaSimctl: !unit.hostPath.isEmpty && unit.isAppHosted && result.log.hasSuffix("host.log")))",
                     "  driver: \(events.processID.map { "started in process \($0)" } ?? "did not report (the driver library was not loaded, or the app did not finish launching)")",
                     "  runs without mutants: \(events.controls.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value.status), \($0.value.tests) tests, \(String(format: "%.1f", $0.value.seconds))s" }.joined(separator: "; "))",
                     "  one run: \(events.single.map { "\($0.status), \($0.tests) tests" } ?? "-")",
                     "  stop: \(events.stop ?? "-")"]
        // The tests that started in the runs without mutants at the start of the process, in order (tests.log)
        if let directory = result.log.isEmpty ? nil : URL(fileURLWithPath: result.log).deletingLastPathComponent(),
           let text = try? String(contentsOf: directory.appendingPathComponent("tests.log"), encoding: .utf8) {
            let started = text.split(separator: "\n")
            lines.append("  tests started in the runs without mutants: \(started.count)" + (started.last.map { "; the last one: \($0)" } ?? ""))
        }
        let reports = crashReports(for: unit, since: start)
        lines.append("  crash reports since the start: " + (reports.isEmpty ? "none found in ~/Library/Logs/DiagnosticReports" : ""))
        lines += reports.map { "    " + $0 }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Crash reports of the host's executable that were written after `start` (simulator and macOS processes both
    /// report to the user's DiagnosticReports).
    static func crashReports(for unit: Target, since start: Date) -> [String] {
        crashReports(hostName: URL(fileURLWithPath: unit.hostPath).deletingPathExtension().lastPathComponent, since: start)
    }

    static func crashReports(hostName name: String, since start: Date) -> [String] {
        guard !name.isEmpty else { return [] }
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { file in
            guard file.lastPathComponent.hasPrefix(name + "-") || file.lastPathComponent.hasPrefix(name + "_") else { return false }
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return modified >= start.addingTimeInterval(-1)
        }.map(\.path).sorted()
    }

    /// Crash reports written after `start` for an app with one of these bundle identifiers (the first line of an
    /// `.ips` file is JSON that names the bundle).
    /// - Parameter device: the UDID of the simulator the app ran on; a report of the same app on another simulator
    ///   (a second run on the same Mac) is then left out. nil: not asked.
    static func crashReports(bundleIdentifiers: [String], since start: Date, device: String? = nil, in directory: URL? = nil) -> [String] {
        guard !bundleIdentifiers.isEmpty else { return [] }
        let directory = directory ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { file in
            guard file.pathExtension == "ips",
                  ((try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) >= start.addingTimeInterval(-1),
                  let handle = FileHandle(forReadingAtPath: file.path) else { return false }
            defer { try? handle.close() }
            let head = String(decoding: handle.readData(ofLength: 4096), as: UTF8.self)
            guard let line = head.split(separator: "\n").first,
                  let header = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let bundle = header["bundleID"] as? String, bundleIdentifiers.contains(bundle) else { return false }
            guard let device else { return true }
            // The path of the process (`procPath`) holds the simulator's directory
            return (try? String(contentsOf: file, encoding: .utf8))?.range(of: device, options: .caseInsensitive) != nil
        }.map(\.path).sorted()
    }

    /// The arguments of a test host that the tool starts, from the `.xctestrun` file. The language and region of a
    /// test-plan configuration are there twice: as `TestLanguage` / `TestRegion`, and (with Xcode 27) already as the
    /// arguments `-AppleLanguages` / `-AppleLocale`, which is how `xcodebuild` hands them to the host. Where only the
    /// first form is there, the arguments are made from it: a host started in another language than the one the
    /// baseline ran in could pass tests that would fail, and a pass in such a host is what makes a mutant Survived.
    static func hostArguments(_ arguments: [String], language: String?, region: String?) -> [String] {
        var result = arguments
        if let language, !language.isEmpty, !arguments.contains("-AppleLanguages") { result += ["-AppleLanguages", "(\(language))"] }
        if let region, !region.isEmpty, !arguments.contains("-AppleLocale") {
            result += ["-AppleLocale", language.map { $0.isEmpty ? region : "\($0)_\(region)" } ?? region]
        }
        return result
    }

    /// What is known to end a test host that the tool started, read from the host's output; nil if nothing known is there.
    static func knownCause(inHostOutput output: String) -> String? {
        if output.contains("activities are disallowed in the current configuration") {
            return "a test uses XCTContext.runActivity, and XCTest refuses activities in a host that has no test configuration saying that they are reported. The tool sets one up where XCTest lets it (events.log has a line `NOTE activities: …` when it could not); with this version of Xcode it could not, so tests that use activities need xcodebuild to start the host."
        }
        return nil
    }

    /// Copies what a process started by the tool left (the host's output, the command and how it ended, the driver's
    /// events, the plan) to `logs/<name>`, which outlives the session directory, and returns a text for the warning:
    /// where the copies are and the last lines the host wrote.
    static func keepEvidence(sessionDirectory: URL, logs: URL, name: String) -> (directory: URL, note: String) {
        let fm = FileManager.default
        let kept = logs.appendingPathComponent(name)
        try? fm.removeItem(at: kept)
        try? fm.createDirectory(at: kept, withIntermediateDirectories: true)
        for file in ["host.log", "launch.txt", "events.log", "plan.json", "tests.log"] {
            try? fm.copyItem(at: sessionDirectory.appendingPathComponent(file), to: kept.appendingPathComponent(file))
        }
        let output = (try? String(contentsOf: kept.appendingPathComponent("host.log"), encoding: .utf8)) ?? ""
        let last = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.suffix(3)
            .map { String($0.prefix(200)) }
        let tail = last.isEmpty ? "the host wrote nothing" : "last output of the host: " + last.joined(separator: " | ")
        let cause = knownCause(inHostOutput: output).map { " Cause: \($0)" } ?? ""
        let started = ((try? String(contentsOf: kept.appendingPathComponent("tests.log"), encoding: .utf8)) ?? "").split(separator: "\n")
        let lastTest = started.last.map { " The last test that started: \($0) (\(started.count) had started)." } ?? ""
        // The crash report of a process is written a few seconds after it has ended (a record made at once says
        // "none found"): looked for again here, for up to six seconds. This is
        // the path of a process that failed, which is rare, so the wait does not slow a run down.
        var crash = ""
        let record = kept.appendingPathComponent("launch.txt")
        let launch = (try? String(contentsOf: record, encoding: .utf8)) ?? ""
        if cause.isEmpty, let hostLine = launch.split(separator: "\n").first(where: { $0.hasPrefix("host: ") }),
           let started = (try? fm.attributesOfItem(atPath: sessionDirectory.appendingPathComponent("launch.txt").path))?[.creationDate] as? Date {
            let host = URL(fileURLWithPath: String(hostLine.dropFirst("host: ".count)).replacingOccurrences(of: " (app)", with: "").replacingOccurrences(of: " (no host app)", with: ""))
                .deletingPathExtension().lastPathComponent
            var reports: [String] = []
            let deadline = Date().addingTimeInterval(crashReportWait)
            repeat {
                reports = crashReports(hostName: host, since: started)
                if !reports.isEmpty || InterruptState.isInterrupted { break }
                Thread.sleep(forTimeInterval: 0.5)
            } while Date() < deadline
            if !reports.isEmpty {
                let described = reports.map { path in "    \(path)" + (describeCrashReport(atPath: path).map { ": \($0)" } ?? "") }
                if let handle = FileHandle(forWritingAtPath: record.path) {
                    handle.seekToEndOfFile()
                    handle.write(Data(("  crash reports found when looked for again, after the process had ended:\n" + described.joined(separator: "\n") + "\n").utf8))
                    try? handle.close()
                }
                crash = " Crash report of the host: \(reports[0])" + (describeCrashReport(atPath: reports[0]).map { " (\($0))" } ?? "") + (reports.count > 1 ? " and \(reports.count - 1) more" : "") + "."
            }
        }
        // `simctl launch` does not say how the app ended. The simulator's system log does: SpringBoard and
        // runningboardd write a line when a process exits, with the signal if there was one. Asked only here, for a
        // process that failed.
        var exit = ""
        if let pid = launch.split(separator: "\n").first(where: { $0.contains("driver: started in process ") })?.split(separator: " ").last.flatMap({ Int($0) }),
           let udid = launch.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { UUID(uuidString: $0) != nil }),
           let started = (try? fm.attributesOfItem(atPath: sessionDirectory.appendingPathComponent("launch.txt").path))?[.creationDate] as? Date,
           let lines = exitLines(simulator: udid, processID: pid, lastSeconds: Int(Date().timeIntervalSince(started)) + 15), !lines.isEmpty {
            if let handle = FileHandle(forWritingAtPath: record.path) {
                handle.seekToEndOfFile()
                handle.write(Data(("  the simulator's system log about the end of process \(pid):\n" + lines.map { "    " + $0 }.joined(separator: "\n") + "\n").utf8))
                try? handle.close()
            }
            exit = " How the process ended, from the simulator's log: \(exitReason(in: lines) ?? lines[lines.count - 1])."
        }
        return (kept, "Kept for inspection in \(kept.path): host.log (output of the host), launch.txt (the command, the environment, how the process ended, crash reports), events.log (what the driver reported), tests.log (the tests that started, in order).\(lastTest)\(exit)\(crash) \(tail)\(cause)")
    }

    /// The lines that SpringBoard and runningboardd wrote about a process that exited, from the system log of a
    /// simulator (the last `lastSeconds` seconds); nil if the log could not be read.
    static func exitLines(simulator udid: String, processID: Int, lastSeconds: Int) -> [String]? {
        let predicate = "(process == \"SpringBoard\" OR process == \"runningboardd\") AND (eventMessage CONTAINS[c] \"exited\" OR eventMessage CONTAINS[c] \"termination reported\")"
        guard let result = try? Subprocess.capture(["xcrun", "simctl", "spawn", udid, "log", "show", "--last", "\(max(lastSeconds, 20))s", "--style", "compact", "--predicate", predicate],
                                                   timeout: 30, ignoresInterrupt: true), result.status == 0 else { return nil }
        return exitLines(inLog: result.output, processID: processID)
    }

    /// The lines of such a log that name the process (`…:<pid>]`), shortened; the last three.
    static func exitLines(inLog log: String, processID: Int) -> [String] {
        log.split(whereSeparator: \.isNewline).filter { $0.contains(":\(processID)]") || $0.contains("pid \(processID)") || $0.contains("pid=\(processID)") || $0.contains("pid:\(processID)") }
            .suffix(3).map { String($0.trimmingCharacters(in: .whitespaces).prefix(400)) }
    }

    /// "signal SIGSEGV(11)" and the like, from lines of the simulator's log about a process that exited.
    static func exitReason(in lines: [String]) -> String? {
        for line in lines.reversed() {
            if let range = line.range(of: #"domain:[A-Za-z]+\(\d+\) code:[A-Za-z0-9_]+\(\d+\)"#, options: .regularExpression) { return String(line[range]) }
            if let range = line.range(of: #"exited (voluntarily|with [^>,]{1,60})"#, options: .regularExpression) { return String(line[range]) }
        }
        return nil
    }

    /// How long a crash report is waited for when the evidence of a process that failed is kept.
    nonisolated(unsafe) static var crashReportWait: TimeInterval = 6

    /// The kind of exception and the first frames of the thread that crashed, from a crash report (`.ips`: one line
    /// of JSON, then the report as JSON); nil if the file is not such a report.
    static func describeCrashReport(atPath path: String) -> String? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8), let newline = text.firstIndex(of: "\n"),
              let report = try? JSONSerialization.jsonObject(with: Data(text[text.index(after: newline)...].utf8)) as? [String: Any] else { return nil }
        let exception = report["exception"] as? [String: Any]
        var parts = [[exception?["type"] as? String, (exception?["signal"] as? String).map { "(\($0))" }].compactMap { $0 }.joined(separator: " ")]
        if let threads = report["threads"] as? [[String: Any]] {
            let index = report["faultingThread"] as? Int ?? threads.firstIndex { $0["triggered"] as? Bool == true } ?? 0
            if threads.indices.contains(index), let frames = threads[index]["frames"] as? [[String: Any]] {
                let images = report["usedImages"] as? [[String: Any]] ?? []
                let names = frames.prefix(5).map { frame -> String in
                    let image = (frame["imageIndex"] as? Int).flatMap { images.indices.contains($0) ? images[$0]["name"] as? String : nil }
                    return ((frame["symbol"] as? String).map { String($0.prefix(120)) } ?? "?") + (image.map { " (\($0))" } ?? "")
                }
                if !names.isEmpty { parts.append("thread that crashed: " + names.joined(separator: " < ")) }
            }
        }
        let described = parts.filter { !$0.isEmpty }.joined(separator: "; ")
        return described.isEmpty ? nil : described
    }

    /// The share of the limit of a run of the whole selection that a run of narrowed tests gets on top of its own.
    static let narrowedRunShare = 0.1

    /// How a process that the tool started ended, for a message.
    /// - Parameter viaSimctl: the process is `simctl launch`, which ends when the app does and does not hand on how.
    static func exitDescription(_ code: Int32?, viaSimctl: Bool = false) -> String {
        guard let code else { return "the process was still running" }
        if code > 128, code < 128 + 64 { return "the process was ended by signal \(code - 128)" }
        if viaSimctl { return code == 0 ? "the app ended; simctl does not say how" : "simctl launch exit status \(code)" }
        return "exit status \(code)"
    }

    /// Launches the test host of one unit once and lets the driver run `mode`. Returns when the driver is done, the
    /// process ended, a run took too long, or the tool was interrupted.
    /// - Parameter expectedTests: number of tests the first run without mutants must have; nil if not known yet.
    /// - Parameter singleTimeout: seconds allowed for the one run of mode `single`.
    /// - Parameter gate: whether this process makes the two runs without mutants (mode `session`).
    /// - Parameter limits: seconds allowed for one run of a mutant's narrowed tests in mode `session`, by mutant
    ///   (`TimeoutPolicy.sessionLimit`; a share of the limit of a whole run is added). A mutant without an entry gets
    ///   the limit of a run of the whole selection, and no run ever gets more than that.
    /// - Parameter onProgress: called whenever the driver has reported something new, with everything reported so far.
    static func runSession(_ mode: Mode, setup: Setup, unit unitIndex: Int, launcher: Launcher, expectedTests: Int?, xcode: Xcode, directory: URL,
                           singleTimeout: Double = 0, gate: Gate = .full, limits: [Int: Double] = [:],
                           onProgress: (Events) throws -> Void = { _ in }) throws -> SessionResult {
        let unit = setup.units[unitIndex]
        let fm = FileManager.default
        try? fm.removeItem(at: directory)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let region = directory.appendingPathComponent("shared.bin")
        var environment = [SharedProcessDriverSource.sessionEnvironmentVariable: directory.path]
        var plan = Plan(bundlePath: unit.target.bundlePath, bundleName: URL(fileURLWithPath: unit.target.bundlePath).lastPathComponent,
                        sharedPath: region.path, moduleName: unit.target.moduleName, only: unit.target.only, skip: unit.target.skip, mutants: [])
        switch mode {
        case let .session(entries):
            var cells = [Int](repeating: 0, count: Instrumenter.sharedHeaderCount + setup.switchCount)
            cells[0] = -1
            cells[2] = setup.switchCount
            try cells.withUnsafeBytes { Data($0) }.write(to: region)
            plan.mutants = entries
            plan.confirm = setup.confirmation.rawValue
            if case let .known(tests, _) = gate {
                plan.gate = "known"
                plan.controlTests = tests
            }
            environment[setup.names.shared] = region.path
        case let .single(entry, active, trace):
            plan.mode = "single"
            plan.single = entry
            // With a mutant on, only a pass is taken from this run; a failure is decided under xcodebuild
            if active != nil { plan.stopAtFirstFailure = true }
            if let active { environment[setup.names.active] = String(active) }
            if let trace { environment[setup.names.trace] = trace.path }
        }
        try JSONEncoder().encode(plan).write(to: directory.appendingPathComponent("plan.json"))
        fm.createFile(atPath: directory.appendingPathComponent("none.xctestconfiguration").path, contents: nil)
        let xctestrun = directory.appendingPathComponent("session.xctestrun")
        let eventsFile = directory.appendingPathComponent("events.log")
        let log = directory.appendingPathComponent(launcher == .direct ? "host.log" : "xcodebuild.log")
        var result = SessionResult(log: log.path)

        var arguments: [String]
        var processEnvironment: [String: String] = [:]
        var simulatorApp: (udid: String, bundleIdentifier: String)?
        switch launcher {
        case .xcodebuild:
            try writeXctestrun(original: setup.originalXctestrun, target: unit.target, driverBundle: unit.driver.bundle, environment: environment, to: xctestrun)
            arguments = ["xcodebuild", "test-without-building", "-xctestrun", xctestrun.path,
                         "-destination", xcode.options.destination, "-collect-test-diagnostics", "never",
                         "-resultBundlePath", directory.appendingPathComponent("session.xcresult").path,
                         "-derivedDataPath", xcode.derivedData.deletingLastPathComponent().appendingPathComponent(xcode.testDerivedDataName).path,
                         "-parallel-testing-enabled", "NO"]
            arguments += xcode.options.extraTestArguments
        case .direct:
            switch directLaunch(unit: unit.target, driver: unit.driver, simulatorUDID: xcode.simulatorUDID, placeholders: setup.placeholders, session: environment) {
            case let .failure(reason):
                result.unusable = reason.description
                return result
            case let .success(launch):
                arguments = launch.arguments
                processEnvironment = launch.environment
                simulatorApp = launch.simulatorApp
            }
        }

        // What was started, for whoever has to find out why a host started by the tool did not do its work
        let launchRecord = directory.appendingPathComponent("launch.txt")
        if launcher == .direct {
            try? launchDescription(arguments: arguments, environment: processEnvironment, unit: unit.target).write(to: launchRecord, atomically: true, encoding: .utf8)
        }
        let process = try Subprocess.spawn(arguments, environment: processEnvironment, logPath: log.path)
        let start = Date()
        var offset: UInt64 = 0
        var buffer = Data()
        var phaseStart = Date()
        var phase = ""
        func readEvents() -> Bool {
            guard let handle = try? FileHandle(forReadingFrom: eventsFile) else { return false }
            defer { try? handle.close() }
            try? handle.seek(toOffset: offset)
            guard let data = try? handle.readToEnd(), !data.isEmpty else { return false }
            offset += UInt64(data.count)
            buffer.append(data)
            while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex...newline)
                result.events.consume(line)
            }
            return true
        }
        /// What the driver is doing now, as a text that changes whenever it moves on (the clock restarts then).
        func currentPhase() -> (name: String, limit: Double) {
            let events = result.events
            if events.processID == nil { return ("launch", setup.launchTimeout) }
            if case .single = mode { return ("single", singleTimeout) }
            let wholeRun: Double
            switch gate {
            case .full:
                guard events.controlsPassed, let first = events.controls[1], let second = events.controls[2] else {
                    return ("control \(events.controls.count)", setup.launchTimeout)
                }
                wholeRun = max(first.seconds, second.seconds)
            case let .known(_, seconds):
                guard events.ready else { return ("launch", setup.launchTimeout) }
                wholeRun = seconds
            }
            // One run of the tests: the run with the mutant on, or the check run after a failure
            let perRun = wholeRun * setup.timeoutFactor + min(setup.timeoutConstant, 10)
            // Narrowed tests: their own time in the baseline, and a tenth of a whole run for what every run costs
            // whatever it selects (finding the tests among all of them)
            let limit = events.current.flatMap { limits[$0] }.map { min($0 + perRun * Self.narrowedRunShare, perRun) } ?? perRun
            return ("mutant \(events.pre.count) \(events.begun.count) \(events.ended.count) \(events.checks.count) \(events.again.count) \(events.checks2.count)", limit)
        }
        var exited = false
        var failure: Error?
        while true {
            if readEvents() {
                do { try onProgress(result.events) } catch { failure = error; break }
            }
            if result.events.done { result.ending = .done; break }
            if result.events.relaunched { result.ending = .exited; break }
            if exited { result.ending = .exited; break }
            if InterruptState.isInterrupted { result.ending = .interrupted; break }
            let now = currentPhase()
            if now.name != phase {
                phase = now.name
                phaseStart = Date()
            } else if Date().timeIntervalSince(phaseStart) > now.limit {
                result.ending = .timedOut
                // The shared region says which mutant is on, and whether its switch was evaluated in this run
                if case .session = mode, let data = try? Data(contentsOf: region), data.count >= 2 * MemoryLayout<Int>.size {
                    let cells = data.withUnsafeBytes { Array($0.bindMemory(to: Int.self).prefix(2)) }
                    if cells[0] >= 0 { result.hang = Hang(id: cells[0], activations: cells[1], seconds: Date().timeIntervalSince(phaseStart), limit: now.limit) }
                }
                break
            }
            // Read once more after the process is gone, so that its last lines are not missed
            if let code = process.poll() {
                exited = true
                result.exitCode = code
            } else {
                usleep(launcher == .direct ? 5_000 : 20_000)
            }
        }
        result.lastPhase = phase
        // Nothing the process would still write is needed: stop it and the test host at once.
        process.kill()
        if let pid = result.events.processID { Darwin.kill(pid, SIGKILL) }
        if let simulatorApp {
            if result.events.processID == nil || result.ending == .timedOut {
                _ = try? Subprocess.capture(["/usr/bin/xcrun", "simctl", "terminate", simulatorApp.udid, simulatorApp.bundleIdentifier], timeout: 30, ignoresInterrupt: true)
            }
        } else if launcher == .xcodebuild, result.ending == .timedOut || result.events.processID == nil {
            xcode.terminateHostApps(xctestrun: xctestrun, logDirectory: directory)
        }
        result.duration = Date().timeIntervalSince(start)
        try? fm.removeItem(at: directory.appendingPathComponent("session.xcresult"))
        if launcher == .direct, let handle = FileHandle(forWritingAtPath: launchRecord.path) {
            handle.seekToEndOfFile()
            handle.write(Data(endDescription(result, unit: unit.target, since: start).utf8))
            try? handle.close()
        }
        if let failure { throw failure }

        let events = result.events
        if result.ending != .interrupted {
            if events.processID == nil {
                let how = result.ending == .timedOut ? "within \(Int(setup.launchTimeout))s"
                    : "(\(exitDescription(result.exitCode, viaSimctl: simulatorApp != nil)), \(String(format: "%.1f", result.duration))s after the start)"
                result.unusable = events.stop ?? "the driver did not start in the test host \(how) (log: \(log.path))"
            } else if case .single = mode {
                // One run: the caller reads `events.single`
            } else if case .known = gate {
                // The process starts with the first mutant: there is nothing here that could rule the mode out
                if let stop = events.stop, stop != "dirty", stop != "precheck" { result.unusable = stop }
            } else if !events.controlsPassed {
                let failed = [events.controls[1], events.controls[2]].compactMap { $0 }.last
                if let failed {
                    result.unusable = "the tests do not pass twice in a row in one process without mutants (run \(events.controls.count): \(failed.status)\(failed.failed.isEmpty ? "" : "; failed: " + failed.failed.prefix(3).joined(separator: ", ")))"
                } else {
                    let run = events.controls[1] == nil ? "first" : "second"
                    let how = result.ending == .timedOut
                        ? "did not finish the \(run) run of the tests without mutants in \(Int(setup.launchTimeout))s"
                        : "ended during the \(run) run of the tests without mutants (\(exitDescription(result.exitCode, viaSimctl: simulatorApp != nil)), \(String(format: "%.1f", result.duration))s after the start)"
                    result.unusable = "the test process \(how) (log: \(log.path))"
                }
            } else if let tests = events.controls[1]?.tests, let expectedTests, tests != expectedTests {
                result.unusable = "the driver ran \(tests) tests where \(expectedTests) were expected from the baseline"
            } else if let stop = events.stop, stop != "dirty" {
                result.unusable = stop
            }
            if case .session = mode, case .full = gate, events.classesWritten,
               let text = try? String(contentsOf: directory.appendingPathComponent("classes.txt"), encoding: .utf8) {
                result.classes = Classes.parse(text)
            }
        }
        return result
    }
}
