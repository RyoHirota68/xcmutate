import Foundation
import MutatorCore

/// `xcmutate init`: finds out how the project is built and tested, tries the faster modes on a sample of mutants, and
/// writes the run options into the config file `xcmutate.yml` (a `run` object and the profiles `pr` and `nightly`).
///
/// It never chooses an option that makes verdicts weaker (`--no-recheck-survivors`, `--trust-shared-survivors`,
/// `--confirm-kills none`), and it chooses no gate: those are decisions of the project. A faster mode is chosen only
/// when it gave the same verdicts as the default mode on the sample.
public enum ProjectSetup {
    public struct Options: Sendable {
        public var root: URL
        public var workspace: String?
        public var project: String?
        public var package: String?
        public var scheme: String?
        public var destination: String?
        public var configFile: URL
        /// The JSON file of an earlier version at the root, which init moves into `configFile` (`targets`).
        public var legacyConfig: URL?
        /// Swift files (relative to the root) that the trials mutate: the sample is taken from them.
        public var files: [String] = []
        /// A directory (relative to the root): the trials mutate the Swift files below it.
        public var path: String?
        /// `--build-arg`, `--package-cache`, `--work-dir`: used for the build and the trials, and written into `run`.
        public var buildArguments: [String] = []
        public var packageCache: String?
        public var workDir: String?
        public var dryRun = false
        public var yes = false
        public var force = false
        /// The executable of the tool, for the trial runs.
        public var executable: String
        public var sample = 10

        /// The current directory of init (relative paths that were given are relative to it).
        public var cwd: URL

        public init(root: URL, configFile: URL, executable: String, cwd: URL? = nil) {
            self.cwd = cwd ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            self.root = root
            self.configFile = configFile
            self.executable = executable
        }
    }

    public struct Failure: Error, CustomStringConvertible {
        public var description: String
        init(_ text: String) { description = text }
    }

    // MARK: What was found

    /// The facts the recommendation rests on.
    public struct Facts: Equatable {
        public var container: (kind: String, path: String)
        public var scheme: String
        public var destination: String
        public var isSimulator: Bool
        public var configurations: [String] = []
        public var unitTargets: [String] = []
        public var uiTargets: [String] = []
        public var appHosted = false
        public var randomOrder = false
        public var defaultBranch: String?
        public var cores = ProcessInfo.processInfo.activeProcessorCount
        public var memoryGB = Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)
        /// The destination to write: the simulator by its name and OS version (`destination` is its UDID, which only
        /// this Mac knows); nil to write `destination`.
        public var fileDestination: String?
        /// Why the privacy settings of the simulator could not be given to another simulator; nil when they could
        /// (then worker simulators of `run --workers` get them too).
        public var workerPrivacyProblem: String?
        /// Where the nightly profile writes the impact map (outside what git tracks), and why there.
        public var impactMap = (path: "", why: "")
        /// `--build-arg`, `--package-cache`, `--work-dir` as they are written into `run`.
        public var buildArguments: [String] = []
        public var packageCache: String?
        public var workDir: String?

        public static func == (a: Facts, b: Facts) -> Bool {
            a.container.kind == b.container.kind && a.container.path == b.container.path && a.scheme == b.scheme && a.destination == b.destination
                && a.isSimulator == b.isSimulator && a.configurations == b.configurations && a.unitTargets == b.unitTargets && a.uiTargets == b.uiTargets
                && a.appHosted == b.appHosted && a.randomOrder == b.randomOrder && a.defaultBranch == b.defaultBranch && a.cores == b.cores && a.memoryGB == b.memoryGB
                && a.fileDestination == b.fileDestination && a.workerPrivacyProblem == b.workerPrivacyProblem && a.impactMap == b.impactMap
                && a.buildArguments == b.buildArguments && a.packageCache == b.packageCache && a.workDir == b.workDir
        }

        public init(container: (kind: String, path: String), scheme: String, destination: String, isSimulator: Bool) {
            self.container = container
            self.scheme = scheme
            self.destination = destination
            self.isSimulator = isSimulator
        }
    }

    /// What one trial run on the sample gave.
    public struct Trial: Sendable, Equatable {
        public var exitCode: Int32
        public var statuses: [String: String] = [:]
        public var testCount = 0
        public var baselineSeconds = 0.0
        public var finalBaselineSeconds = 0.0
        /// Mutants in the report, and those of them that were run (not NotReached, not reused).
        public var mutants = 0
        public var executed = 0
        /// Wall-clock time of the mutant phase, and the part of it spent on the runs without mutants at the start of
        /// shared processes (`durations.breakdown.startupRunSeconds`), which does not grow with the number of mutants.
        public var phaseSeconds: Double?
        public var startupSeconds = 0.0
        /// The time a run spends per mutant run: the mutant phase without the runs at the start of shared processes,
        /// divided by the mutants that were run.
        public var secondsPerMutant: Double?
        public var warnings: [String: String] = [:]
        public var restoredStates: Int?
        public var restoreFallbacks: Int?
        public init(exitCode: Int32) { self.exitCode = exitCode }
    }

    public struct Recommendation {
        /// The `run` object and the profiles, ready to be written into the config file.
        public var run: [String: Any]
        public var profiles: [String: [String: Any]]
        /// One line per choice, also written into the file (`_why`).
        public var reasons: [String]
        public var estimate: String
    }

    // MARK: Choosing

    /// The configuration for these facts and trials (a pure function: the choices and their reasons).
    public static func recommend(facts: Facts, plain: Trial, fast: Trial?, fastOptions: [String]) -> Recommendation {
        var run: [String: Any] = [facts.container.kind: facts.container.path, "scheme": facts.scheme, "destination": facts.fileDestination ?? facts.destination]
        var why: [String: String] = [:]
        var reasons: [String] = []
        func note(_ key: String, _ text: String) {
            why[key] = text
            reasons.append("\(key): \(text)")
        }
        note(facts.container.kind, "the \(facts.container.kind) found at the top of the repository")
        note("scheme", "the scheme used for the trials")
        if !facts.isSimulator {
            note("destination", "the tests run on macOS")
        } else if facts.fileDestination != nil {
            note("destination", "the simulator used for the trials, by its name and OS version, so that the file works on another Mac with a simulator of that name (its UDID is \(facts.destination.replacingOccurrences(of: "id=", with: "")) on this Mac only)")
        } else {
            note("destination", "the simulator used for the trials, by its UDID: its name and OS version do not name it alone (another simulator has them); give a destination by name when the file is used on other Macs")
        }
        if !facts.buildArguments.isEmpty {
            run["buildArg"] = facts.buildArguments
            note("buildArg", "given to init, and used for its build and trials")
        }
        if let cache = facts.packageCache {
            run["packageCache"] = cache
            note("packageCache", "given to init, and used for its build and trials")
        }
        if let workDir = facts.workDir {
            run["workDir"] = workDir
            note("workDir", "given to init")
        }
        if !facts.uiTargets.isEmpty {
            run["onlyTesting"] = facts.unitTargets
            note("onlyTesting", "the unit-test targets; UI test targets (\(facts.uiTargets.joined(separator: ", "))) are not supported and are left out")
        }
        if facts.configurations.count > 1 {
            run["onlyTestConfiguration"] = [facts.configurations[0]]
            note("onlyTestConfiguration", "the test plan has \(facts.configurations.count) configurations (\(facts.configurations.joined(separator: ", "))); every one would run the tests again for every mutant. The first is used; name another if the code under test depends on what they vary")
        }
        // The faster modes: only when the sample gave the same verdicts with them
        var shared = false
        var restore = false
        var fastReason = "no trial of the faster modes was possible"
        if let fast {
            let common = Set(plain.statuses.keys).intersection(fast.statuses.keys)
            let differing = common.filter { plain.statuses[$0] != fast.statuses[$0] }.sorted()
            if fast.exitCode != 0 && fast.exitCode != 3 {
                fastReason = "the trial with \(fastOptions.joined(separator: " ")) did not complete (exit code \(fast.exitCode))"
            } else if !differing.isEmpty {
                fastReason = "the trial with \(fastOptions.joined(separator: " ")) gave other verdicts than the default mode for \(differing.count) of \(common.count) mutants, so it is not used"
            } else if fast.warnings["sharedProcessUnavailable"] != nil {
                fastReason = "shared processes cannot be used here: \(fast.warnings["sharedProcessUnavailable"] ?? "")"
            } else if let slower = slowerReason(plain: plain, fast: fast, fastOptions: fastOptions) {
                fastReason = slower
            } else {
                shared = fastOptions.contains("--shared-process")
                restore = fastOptions.contains("restore") && fast.warnings["restoreUnavailable"] == nil && (fast.restoreFallbacks ?? 0) == 0
                fastReason = String(format: "the same verdicts as the default mode for all %d mutants of the sample, and %.1f s per mutant against %.1f s", common.count, fast.secondsPerMutant ?? 0, plain.secondsPerMutant ?? 0)
            }
        }
        var pr: [String: Any] = ["selectTests": "reach"]
        var prWhy: [String: String] = ["selectTests": "each mutant runs the suites that reached it, and a survivor is rechecked against all tests (\"impact\" with the nightly map makes the selection smaller; see docs/usage.md)"]
        var nightly: [String: Any] = ["selectTests": "reach", "writeImpactMap": facts.impactMap.path, "timeLimit": "3h"]
        var nightlyWhy: [String: String] = [
            "selectTests": "as for pull requests",
            "writeImpactMap": "the map that pull requests can use with selectTests \"impact\" and impactMap; \(facts.impactMap.why)",
            "timeLimit": "a nightly run ends with a report even if it does not finish; set it below the job's timeout",
        ]
        if let branch = facts.defaultBranch {
            pr["since"] = branch
            prWhy["since"] = "the lines changed since the default branch"
        }
        if shared {
            pr["sharedProcess"] = "auto"
            prWhy["sharedProcess"] = "shared processes when they save time for the number of mutants (\(fastReason))"
            nightly["sharedProcess"] = true
            nightlyWhy["sharedProcess"] = "many mutants run in one test process (\(fastReason))"
        } else {
            prWhy["sharedProcess"] = "not used: \(fastReason)"
            nightlyWhy["sharedProcess"] = "not used: \(fastReason)"
        }
        if restore {
            pr["confirmKills"] = "restore"
            prWhy["confirmKills"] = "the simulator is put back instead of a run without mutants after a detection; the trial put it back every time. It assumes tests that depend on nothing outside the simulator"
            nightly["confirmKills"] = "restore"
            nightlyWhy["confirmKills"] = prWhy["confirmKills"]
        } else if facts.isSimulator && facts.appHosted {
            prWhy["confirmKills"] = "the default (auto): putting the simulator back could not be shown to stand for a run without mutants in the trial"
        }
        if facts.randomOrder {
            prWhy["order"] = "the tests run in random order: mutants run alone against all tests are run to the end"
        }
        if facts.isSimulator {
            let workers = max(1, min(4, facts.cores / 4, facts.memoryGB / 8))
            if workers > 1, let problem = facts.workerPrivacyProblem {
                nightlyWhy["workers"] = "one simulator: the privacy settings of the simulator could not be given to the worker simulators that more workers would create (\(problem)), and a permission dialog there stops shared processes and fails tests"
            } else if workers > 1 {
                nightly["workers"] = workers
                nightlyWhy["workers"] = "\(workers) simulators at once (\(facts.cores) cores, \(facts.memoryGB) GB: one per four cores and eight GB, at most four)"
                // Putting the simulator back works with one worker only; for many mutants the workers save more
                if nightly["confirmKills"] != nil {
                    nightly["confirmKills"] = nil
                    nightlyWhy["confirmKills"] = "the default (auto): putting the simulator back works with one worker, and \(workers) workers save more on a nightly run"
                }
            }
        }
        pr["_why"] = prWhy
        pr["_gateExamples"] = ["failOnSurvived": true, "baselineReport": "baseline/mutation.json", "stopWhenGateDecided": true]
        prWhy["_gateExamples"] = "no gate is chosen: put one of these keys into the profile when the project has decided on one"
        pr["_why"] = prWhy
        nightly["_why"] = nightlyWhy
        run["_why"] = why
        for (key, text) in prWhy.sorted(by: { $0.key < $1.key }) where key != "_gateExamples" { reasons.append("pr.\(key): \(text)") }
        for (key, text) in nightlyWhy.sorted(by: { $0.key < $1.key }) { reasons.append("nightly.\(key): \(text)") }
        let estimate = Self.estimate(plain: plain, fast: shared ? fast : nil, mutants: 50)
        return Recommendation(run: run, profiles: ["pr": pr, "nightly": nightly], reasons: reasons, estimate: estimate)
    }

    /// Why the faster modes are not used although they gave the same verdicts: they were not faster per mutant in the
    /// trial (or the trial ran no mutant to tell). nil when they were faster. The runs without mutants at the start of
    /// a shared process are left out of the comparison: they are paid once per process, not per mutant, and
    /// `sharedProcess: "auto"` weighs them against the number of mutants of each run.
    static func slowerReason(plain: Trial, fast: Trial, fastOptions: [String]) -> String? {
        guard let plainEach = plain.secondsPerMutant, let fastEach = fast.secondsPerMutant else {
            return "the trials ran no mutant, so \(fastOptions.joined(separator: " ")) was not shown to be faster"
        }
        guard fastEach < plainEach else {
            return String(format: "the trial with %@ was not faster: %.1f s per mutant against %.1f s in the default mode (the whole mutant phase took %.0f s against %.0f s)",
                          fastOptions.joined(separator: " "), fastEach, plainEach, fast.phaseSeconds ?? 0, plain.phaseSeconds ?? 0)
        }
        return nil
    }

    /// What a run of `mutants` mutants would take after the build, from a trial: the time per mutant run, for the share
    /// of the sample's mutants that were run (the others are NotReached and cost nothing), plus what does not grow with
    /// the number of mutants (the baseline, the final baseline, the runs at the start of a shared process).
    static func estimate(plain: Trial, fast: Trial?, mutants: Int) -> String {
        let trial = fast ?? plain
        guard let each = trial.secondsPerMutant else { return "no estimate: the trial gave no time per mutant" }
        let share = trial.mutants > 0 ? Double(trial.executed) / Double(trial.mutants) : 1
        let fixed = plain.baselineSeconds + (trial.finalBaselineSeconds > 0 ? trial.finalBaselineSeconds : plain.baselineSeconds) + (fast != nil ? trial.startupSeconds : 0)
        let seconds = fixed + each * Double(mutants) * share
        let minutes = Int(seconds / 60 + 0.5)
        let span = seconds < 60 ? "under a minute" : "roughly \(minutes) minute\(minutes == 1 ? "" : "s")"
        return String(format: "a pull request with %d mutants: %@ after the build (in the trial %d of %d mutants were run, %.1f s each; %.0f s do not depend on the number of mutants: the baseline, the final baseline%@)",
                      mutants, span, trial.executed, trial.mutants, each, fixed, fast != nil ? ", the runs without mutants at the start of a shared process" : "")
    }

    /// Where the nightly profile writes the impact map: never inside what git tracks (a map written there makes the
    /// working tree dirty, and the next map is then filed under a commit that does not hold it), and not in a work
    /// directory (`clean` removes those). In `.build` when git ignores it; else beside the default work directories,
    /// named after the repository and a hash of its path (two checkouts of the same name do not share a map).
    static func impactMapPath(root: URL, ignoredByGit: (String) -> Bool) -> (path: String, why: String) {
        let inBuild = ".build/\(ToolInfo.name)/impact.json"
        if ignoredByGit(inBuild) { return (inBuild, "in .build, which git ignores") }
        let hash = String(WorkDirectoryInfo.stableHash(CanonicalPath.of(root)), radix: 16)
        return ("~/Library/Caches/\(ToolNaming.cacheDirectoryName)/impact-\(root.lastPathComponent)-\(hash).json",
                "beside the default work directories, outside the repository (a file inside it would make the working tree dirty) and outside any work directory (clean removes those)")
    }

    /// Whether the text says that the disk is full, in the words of the system (`No space left on device`, `ENOSPC`,
    /// Foundation's out-of-space error). With `errorLinesOnly`, only lines that report an error are read: the output
    /// of a trial holds the output of the project's tests, which may say anything.
    static func saysDiskFull(_ text: String, errorLinesOnly: Bool = false) -> Bool {
        let words = ["No space left on device", "ENOSPC", "NSFileWriteOutOfSpaceError", "error 640"]
        let lines = errorLinesOnly
            ? text.split(whereSeparator: \.isNewline).filter { $0.range(of: "error", options: .caseInsensitive) != nil || $0.hasPrefix("\(ToolInfo.name):") }
            : [Substring(text)]
        return lines.contains { line in words.contains { line.contains($0) } }
    }

    /// The bytes free for `url`'s volume, as text (`12.3 GB`); nil if not known.
    static func freeSpace(at url: URL) -> String? {
        var existing = url
        while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" { existing.deleteLastPathComponent() }
        guard let values = try? existing.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let bytes = values.volumeAvailableCapacityForImportantUsage else { return nil }
        return String(format: "%.1f GB", Double(bytes) / 1_000_000_000)
    }

    /// The config file with the recommendation in it: the other keys of an existing file are kept.
    public static func merged(existing: [String: Any]?, with recommendation: Recommendation) -> [String: Any] {
        var file = existing ?? [:]
        file["run"] = recommendation.run
        file["profiles"] = recommendation.profiles
        file["_estimate"] = recommendation.estimate
        file["_written"] = "by \(ToolInfo.name) init \(ToolInfo.version); the `_` keys are explanations and are not read"
        return file
    }

    /// The comment lines at the top of the file that init writes (and replaces when it writes again).
    static var header: String {
        [
            "# The config file of \(ToolInfo.name). The run options (run, profiles): \(ConfigFile.runOptionsDocumentation)",
            "# The other keys (exclude, operators, ...): \(ConfigFile.keysDocumentation)",
        ].joined(separator: "\n")
    }

    /// `text` without what an earlier init wrote besides `run` and `profiles`: its header lines and its paragraph
    /// "Written by …" (so that writing again replaces them instead of adding more).
    static func removingInitComments(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        var result: [String] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if line.hasPrefix("# The config file of \(ToolInfo.name).") || line.hasPrefix("# The other keys (exclude, operators, ...):") {
                index += 1
            } else if line.hasPrefix("# Written by \(ToolInfo.name) init ") {
                index += 1
                while index < lines.count, lines[index].hasPrefix("#") { index += 1 }
            } else {
                result.append(line)
                index += 1
            }
        }
        return result.joined(separator: "\n")
    }

    /// The YAML file with the recommendation: `run` and `profiles`, with the reasons as comments beside the keys.
    /// `existingText`: a YAML file that is there; its other keys and its comments are kept (its `run` and `profiles`
    /// and what an earlier init wrote around them are replaced). `carried`: keys of a JSON file of an earlier version,
    /// written after them; `notes`: its explanations (`_` keys), as comments above those keys.
    static func yamlDocument(_ recommendation: Recommendation, existingText: String?, carried: [String: Any], notes: [String] = []) -> String {
        var parts = [header]
        if let existingText {
            let kept = removingInitComments(ConfigFile.removingTopLevel(["run", "profiles"], from: existingText)).trimmingCharacters(in: .newlines)
            if !kept.isEmpty { parts.append(kept) }
        }
        if !carried.isEmpty || !notes.isEmpty {
            var block = notes.map { ConfigFile.comment($0, indent: 0) }
            if !carried.isEmpty { block.append(String(ConfigFile.yaml(carried, indent: 0).dropFirst())) }
            parts.append(block.joined(separator: "\n"))
        }
        var written = ConfigFile.comment("Written by \(ToolInfo.name) init \(ToolInfo.version). Each choice has its reason above it. Estimate: \(recommendation.estimate).", indent: 0)
        written += "\nrun:\n" + yamlBlock(recommendation.run, indent: 2)
        written += "\nprofiles:"
        for name in recommendation.profiles.keys.sorted() {
            written += "\n  \(ConfigFile.yamlKey(name)):\n" + yamlBlock(recommendation.profiles[name] ?? [:], indent: 4)
        }
        parts.append(written)
        return parts.joined(separator: "\n\n") + "\n"
    }

    /// The keys of a `run` object or a profile, each with its reason (`_why`) as a comment above it; the reasons for
    /// what was not chosen, and the gates (`_gateExamples`) as commented-out keys, after them.
    static func yamlBlock(_ object: [String: Any], indent: Int) -> String {
        let pad = String(repeating: " ", count: indent)
        let why = object["_why"] as? [String: String] ?? [:]
        var lines: [String] = []
        for key in object.keys.sorted() where !key.hasPrefix("_") {
            if let text = why[key] { lines.append(ConfigFile.comment(text, indent: indent)) }
            lines.append(pad + ConfigFile.yamlKey(key) + ":" + ConfigFile.yaml(object[key]!, indent: indent + 2))
        }
        for (key, text) in why.sorted(by: { $0.key < $1.key }) where object[key] == nil && !key.hasPrefix("_") {
            lines.append(ConfigFile.comment("\(key): \(text)", indent: indent))
        }
        if let gates = object["_gateExamples"] as? [String: Any] {
            lines.append(ConfigFile.comment(why["_gateExamples"] ?? "gates", indent: indent))
            for key in gates.keys.sorted() { lines.append("\(pad)# \(key):\(ConfigFile.yaml(gates[key]!, indent: 0))") }
        }
        return lines.joined(separator: "\n")
    }

    /// The values that a config file holds as the run reads them: `_` keys of a recommendation left out.
    static func withoutExplanations(_ value: Any) -> Any {
        if let object = value as? [String: Any] {
            return object.filter { !$0.key.hasPrefix("_") }.mapValues(withoutExplanations)
        }
        if let array = value as? [Any] { return array.map(withoutExplanations) }
        return value
    }

    /// Whether two values are the same as JSON (the types that the files hold).
    static func sameValue(_ a: Any, _ b: Any) -> Bool {
        let options: JSONSerialization.WritingOptions = [.sortedKeys, .fragmentsAllowed]
        guard JSONSerialization.isValidJSONObject([a]), JSONSerialization.isValidJSONObject([b]) else { return false }
        guard let left = try? JSONSerialization.data(withJSONObject: a, options: options),
              let right = try? JSONSerialization.data(withJSONObject: b, options: options) else { return false }
        return left == right
    }

    /// What init writes: the file, its text, and the file of an earlier version that the new one replaces.
    struct Output {
        var file: URL
        var text: String
        var replaces: URL?
        /// Set when the comments of an existing YAML file could not be kept (the file was written anew from its values).
        var commentsLost = false
    }

    /// Where init writes, and the JSON file of an earlier version at the root that it moves into that file: the file
    /// named with --config (a `.json` one is written as JSON and moves nothing); else the YAML file at the root, or a
    /// new `xcmutate.yml`. Two YAML files at the root stop it.
    public static func targets(given: URL?, root: URL) throws -> (target: URL, legacy: URL?) {
        let json = root.appendingPathComponent(ConfigFile.jsonName)
        let legacy = FileManager.default.fileExists(atPath: json.path) ? json : nil
        if let given {
            if ConfigFile.format(of: given) == .json { return (given, nil) }
            return (given, legacy.flatMap { CanonicalPath.of($0) == CanonicalPath.of(given) ? nil : $0 })
        }
        let yamls = [ConfigFile.yamlName, ConfigFile.yamlAlternativeName].map { root.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        if yamls.count > 1 { throw ConfigFile.Ambiguous(paths: yamls.map(\.path) + (legacy.map { [$0.path] } ?? [])) }
        return (yamls.first ?? root.appendingPathComponent(ConfigFile.yamlName), legacy)
    }

    /// The settings the trials read: those of the file and, under them, those of the JSON file that is moved into it.
    static func settings(target: URL, legacy: URL?) throws -> [String: Any] {
        let own = try ConfigFile.object(at: target) ?? [:]
        let old = try legacy.flatMap { try ConfigFile.object(at: $0) } ?? [:]
        return old.merging(own) { $1 }.filter { !$0.key.hasPrefix("_") && !($0.value is NSNull) }
    }

    /// The output for the recommendation. A `.json` target is written as JSON, as before. Otherwise YAML: into the
    /// YAML file that is there (keeping its other keys and comments), or into a new file; the settings of `legacy` (the
    /// JSON file of an earlier version) that the YAML file does not have are carried over, its explanations as
    /// comments, and the new file replaces it. The text must read back as what it is meant to hold.
    static func output(_ recommendation: Recommendation, target: URL, legacy: URL?) throws -> Output {
        let existing = try ConfigFile.object(at: target)
        if ConfigFile.format(of: target) == .json {
            return Output(file: target, text: json(merged(existing: existing, with: recommendation)))
        }
        let old = try legacy.flatMap { try ConfigFile.object(at: $0) } ?? [:]
        let own = (existing ?? [:]).filter { $0.key != "run" && $0.key != "profiles" }
        let carried = old.filter { $0.key != "run" && $0.key != "profiles" && !$0.key.hasPrefix("_") && own[$0.key] == nil }
        let notes = old.filter { $0.key.hasPrefix("_") && $0.key != "_why" }.sorted { $0.key < $1.key }
            .map { "From \(legacy?.lastPathComponent ?? ConfigFile.jsonName): \($0.key): \(($0.value as? String) ?? "\($0.value)")" }
        let expected = own.merging(carried) { $1 }
            .merging(["run": withoutExplanations(recommendation.run), "profiles": withoutExplanations(recommendation.profiles)]) { $1 }
        let existingText = existing == nil ? nil : try String(contentsOf: target, encoding: .utf8)
        var output = Output(file: target, text: yamlDocument(recommendation, existingText: existingText, carried: carried, notes: notes), replaces: legacy)
        if let read = try? ConfigFile.yamlValue(output.text), sameValue(read, expected) { return output }
        // A file that cannot be edited by lines (flow style, for one): written anew from its values
        output.text = yamlDocument(recommendation, existingText: nil, carried: own.merging(carried) { $1 }, notes: notes)
        output.commentsLost = existingText != nil
        guard let read = try? ConfigFile.yamlValue(output.text), sameValue(read, expected) else {
            throw Failure("the file that init would write to \(target.path) does not read back as the values it is meant to hold; nothing was written")
        }
        return output
    }

    public static func json(_ object: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(object), let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return "{}" }
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    // MARK: Finding out

    static func capture(_ arguments: [String], cwd: String? = nil, timeout: TimeInterval = 600) -> (status: Int32, output: String) {
        (try? Subprocess.capture(arguments, cwd: cwd, timeout: timeout)) ?? (-1, "")
    }

    /// The workspace, project or package at the root (or as given), and its scheme.
    static func container(_ options: Options) throws -> (kind: String, path: String) {
        if let workspace = options.workspace { return ("workspace", workspace) }
        if let project = options.project { return ("project", project) }
        if let package = options.package { return ("package", package) }
        let items = (try? FileManager.default.contentsOfDirectory(atPath: options.root.path)) ?? []
        let workspaces = items.filter { $0.hasSuffix(".xcworkspace") }.sorted()
        let projects = items.filter { $0.hasSuffix(".xcodeproj") }.sorted()
        if workspaces.count == 1 { return ("workspace", workspaces[0]) }
        if workspaces.isEmpty, projects.count == 1 { return ("project", projects[0]) }
        if workspaces.isEmpty, projects.isEmpty, items.contains("Package.swift") { return ("package", ".") }
        let found = workspaces + projects + (items.contains("Package.swift") ? ["Package.swift"] : [])
        throw Failure(found.isEmpty
            ? "no workspace, project or Package.swift at the top of \(options.root.path); name one with --workspace, --project or --package"
            : "more than one of \(found.joined(separator: ", ")) at the top of the repository; name one with --workspace, --project or --package")
    }

    static func containerArguments(_ container: (kind: String, path: String)) -> [String] {
        container.kind == "package" ? [] : ["-\(container.kind)", container.path]
    }

    static func scheme(_ options: Options, container: (kind: String, path: String)) throws -> String {
        if let scheme = options.scheme { return scheme }
        let cwd = container.kind == "package" ? options.root.appendingPathComponent(container.path).path : options.root.path
        // `-list` resolves the packages of a package or workspace into DerivedData and takes no -derivedDataPath; the
        // user default IDECustomDerivedDataLocation keeps it out of the default DerivedData
        let derivedData = FileManager.default.temporaryDirectory.appendingPathComponent("\(ToolInfo.name)-list-\(getpid())")
        defer {
            try? FileManager.default.removeItem(at: derivedData)
            PackageLockFiles.remove(under: derivedData)
        }
        let listed = capture(["/usr/bin/xcrun", "xcodebuild", "-list", "-json"] + containerArguments(container) + ["-IDECustomDerivedDataLocation=\(derivedData.path)"],
                             cwd: cwd, timeout: 300)
        guard listed.status == 0, let start = listed.output.firstIndex(of: "{"),
              let object = try? JSONSerialization.jsonObject(with: Data(listed.output[start...].utf8)) as? [String: Any] else {
            throw Failure("`xcodebuild -list` did not list the schemes; name one with --scheme")
        }
        let body = (object["workspace"] ?? object["project"]) as? [String: Any]
        let schemes = body?["schemes"] as? [String] ?? []
        guard !schemes.isEmpty else { throw Failure("`xcodebuild -list` lists no scheme; name one with --scheme") }
        if schemes.count == 1 { return schemes[0] }
        let name = URL(fileURLWithPath: container.path == "." ? options.root.lastPathComponent : container.path).deletingPathExtension().lastPathComponent
        let preferred = schemes.first { $0 == name } ?? schemes.first { $0 == "\(name)-Package" }
        if let preferred, options.yes { return preferred }
        throw Failure("the schemes are \(schemes.joined(separator: ", ")); name one with --scheme\(preferred.map { " (with --yes, \($0) is taken)" } ?? "")")
    }

    /// A booted iPhone simulator, or nil (then a message says how to boot one).
    static func bootedSimulator() -> (udid: String, name: String)? {
        let listed = capture(["/usr/bin/xcrun", "simctl", "list", "devices", "booted", "-j"], timeout: 60)
        guard let object = try? JSONSerialization.jsonObject(with: Data(listed.output.utf8)) as? [String: Any],
              let devices = object["devices"] as? [String: [[String: Any]]] else { return nil }
        for (runtime, list) in devices.sorted(by: { $0.key > $1.key }) where runtime.contains("iOS") {
            if let device = list.first(where: { ($0["name"] as? String)?.hasPrefix("iPhone") == true }) ?? list.first,
               let udid = device["udid"] as? String { return (udid, device["name"] as? String ?? udid) }
        }
        return nil
    }

    static func defaultBranch(root: URL) -> String? {
        let head = capture(["git", "-C", root.path, "symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"], timeout: 60)
        if head.status == 0, !head.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return head.output.trimmingCharacters(in: .whitespacesAndNewlines) }
        for candidate in ["origin/main", "origin/master", "main", "master"] {
            if capture(["git", "-C", root.path, "rev-parse", "--verify", "--quiet", candidate], timeout: 60).status == 0 { return candidate }
        }
        return nil
    }

    /// Builds for testing (into `derivedData`) and reads the `.xctestrun` file: configurations, targets, the host, the order.
    static func inspectBuild(_ options: Options, facts: inout Facts, derivedData: URL, log: URL) throws {
        let cwd = facts.container.kind == "package" ? options.root.appendingPathComponent(facts.container.path).path : options.root.path
        // The package cache goes where a run puts it: DerivedData's own SourcePackages
        if let cache = options.packageCache {
            let target = derivedData.appendingPathComponent("SourcePackages")
            try FileManager.default.createDirectory(at: derivedData, withIntermediateDirectories: true)
            let copy = try Subprocess.run(["/bin/cp", "-cR", resolved(cache, options).path, target.path], logPath: log.path)
            guard copy.status == 0 else { throw Failure("the package cache \(cache) could not be copied (log: \(log.path))") }
        }
        var arguments = ["/usr/bin/xcrun", "xcodebuild", "build-for-testing"] + containerArguments(facts.container)
        arguments += ["-scheme", facts.scheme, "-destination", facts.destination, "-derivedDataPath", derivedData.path, "COMPILER_INDEX_STORE_ENABLE=NO"]
        arguments += options.buildArguments
        let outcome = try Subprocess.run(arguments, cwd: cwd, logPath: log.path, timeout: 3600)
        guard outcome.status == 0 else { throw Failure("the project does not build for testing with scheme \(facts.scheme) (log: \(log.path))") }
        let products = derivedData.appendingPathComponent("Build/Products")
        guard let xctestrun = ((try? FileManager.default.contentsOfDirectory(at: products, includingPropertiesForKeys: nil)) ?? []).first(where: { $0.pathExtension == "xctestrun" }) else {
            throw Failure("the build wrote no .xctestrun file; does the scheme have a test action?")
        }
        let targets = TestSelector.testTargets(xctestrun: xctestrun)
        facts.unitTargets = targets.filter { !$0.isUITest }.map(\.name)
        facts.uiTargets = targets.filter(\.isUITest).map(\.name)
        guard !facts.unitTargets.isEmpty else { throw Failure("the scheme has no unit-test target (UI tests are not supported)") }
        facts.configurations = Xcode.testConfigurationNames(xctestrun: xctestrun)
        if let data = try? Data(contentsOf: xctestrun), let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            var entries: [[String: Any]] = []
            for configuration in plist["TestConfigurations"] as? [[String: Any]] ?? [] { entries += configuration["TestTargets"] as? [[String: Any]] ?? [] }
            for (key, value) in plist where !key.hasPrefix("__") { if let entry = value as? [String: Any] { entries.append(entry) } }
            let units = entries.filter { $0["IsUITestBundle"] as? Bool != true }
            facts.appHosted = units.contains { $0["IsAppHostedTestBundle"] as? Bool == true || ($0["TestHostPath"] as? String)?.hasSuffix(".app") == true }
            facts.randomOrder = units.contains { ($0["TestExecutionOrdering"] as? String)?.lowercased() == "random" }
        }
    }

    /// A path given to init (relative to the current directory when init was started, which `options.root` is not
    /// always).
    static func resolved(_ path: String, _ options: Options) -> URL {
        URL(fileURLWithPath: RunProfile.expandingHome(path), relativeTo: URL(fileURLWithPath: options.cwd.path, isDirectory: true)).standardizedFileURL
    }

    /// A path for the config file, which a run resolves from the directory of the file: a relative path given to init
    /// (relative to where init was started) is written relative to that directory, with `../` where it is outside, so
    /// that the file works in another checkout; an absolute path or one from the home directory is written as given.
    static func forFile(_ path: String, _ options: Options) -> String {
        if path == "~" || path.hasPrefix("~/") || path.hasPrefix("/") { return path }
        return relativePath(from: CanonicalPath.of(options.configFile.deletingLastPathComponent()), to: CanonicalPath.of(resolved(path, options)))
    }

    /// `target` relative to the directory `base` (both absolute): `.`, `a/b`, `../w`.
    static func relativePath(from base: String, to target: String) -> String {
        let from = base.split(separator: "/").map(String.init)
        let to = target.split(separator: "/").map(String.init)
        var common = 0
        while common < from.count, common < to.count, from[common] == to[common] { common += 1 }
        let parts = Array(repeating: "..", count: from.count - common) + to[common...]
        return parts.isEmpty ? "." : parts.joined(separator: "/")
    }

    /// The Swift files that the trials mutate, relative to the root: the files given, or the files below the
    /// directory given (`--path`, or the current directory when it is below the root) that a run would mutate
    /// (tests, generated code and the `exclude` patterns left out). Empty: the whole repository, as a run without
    /// files. The second value says where the sample comes from.
    static func sampleFiles(_ options: Options, exclude: [String]) throws -> (files: [String], scope: String) {
        let root = CanonicalPath.of(options.root)
        func relative(_ url: URL) -> String? {
            let path = CanonicalPath.of(url)
            if path == root { return "" }
            return path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : nil
        }
        if !options.files.isEmpty {
            let files = try options.files.map { file -> String in
                guard let path = relative(resolved(file, options)), !path.isEmpty else { throw Failure("\(file) is not inside the repository \(root)") }
                return path
            }
            return (files, "the files given (\(files.count))")
        }
        let directory: String
        if let path = options.path {
            guard let found = relative(resolved(path, options)) else { throw Failure("--path \(path) is not inside the repository \(root)") }
            directory = found
        } else if let found = relative(options.cwd), !found.isEmpty {
            directory = found
        } else {
            return ([], "the whole repository (give Swift files or --path <directory> to take it from the code you work on)")
        }
        guard !directory.isEmpty else { return ([], "the whole repository") }
        let listed = capture(["git", "-C", root, "ls-files", "-z", "-co", "--exclude-standard", "--", "\(directory)/*.swift"], timeout: 120)
        let paths = listed.output.split(separator: "\0").map(String.init).filter { $0.hasSuffix(".swift") }
        let selection = FileSelector.select(paths: paths, patterns: exclude) { try? String(contentsOf: options.root.appendingPathComponent($0), encoding: .utf8) }
        guard !selection.included.isEmpty else {
            throw Failure("\(directory) has no Swift file that a run would mutate (tests, generated code and the exclude patterns are left out); give files or another --path")
        }
        return (selection.included, "the \(selection.included.count) Swift files below \(directory)")
    }

    /// One trial run of the tool on the sample.
    static func trial(_ options: Options, facts: Facts, files: [String], extra: [String], work: URL, label: String) -> Trial {
        let report = work.appendingPathComponent("\(label).json")
        var arguments = [options.executable, "run", "--root", options.root.path, "--\(facts.container.kind)", facts.container.path,
                         "--scheme", facts.scheme, "--destination", facts.destination, "--max-mutants", String(options.sample),
                         "--no-caffeinate", "--work-dir", work.appendingPathComponent("work-\(label)").path, "--config", work.appendingPathComponent("config.json").path,
                         "--reporter", "json", "--json-output", report.path]
        for target in facts.uiTargets.isEmpty ? [] : facts.unitTargets { arguments += ["--only-testing", target] }
        if facts.configurations.count > 1 { arguments += ["--only-test-configuration", facts.configurations[0]] }
        for argument in options.buildArguments { arguments.append("--build-arg=\(argument)") }
        if let cache = options.packageCache { arguments += ["--package-cache", resolved(cache, options).path] }
        arguments += extra
        arguments += files
        let log = work.appendingPathComponent("\(label).log")
        let outcome = (try? Subprocess.run(arguments, cwd: options.root.path, logPath: log.path, timeout: 6 * 3600))
        // The trial's work directory holds a build and a copy of the project: not kept once its report is read
        try? FileManager.default.removeItem(at: work.appendingPathComponent("work-\(label)"))
        var trial = Trial(exitCode: outcome?.status ?? -1)
        guard let data = try? Data(contentsOf: report), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return trial }
        return read(report: object, into: trial)
    }

    /// The trial's numbers from its JSON report.
    static func read(report object: [String: Any], into trial: Trial) -> Trial {
        var trial = trial
        let results = object["results"] as? [[String: Any]] ?? []
        trial.mutants = results.count
        for result in results {
            if let mutant = result["mutant"] as? [String: Any], let key = mutant["key"] as? String, let status = result["status"] as? String,
               status != "RunnerError", status != "NotActivated", status != "Ignored", status != "CompileError" {
                trial.statuses[key] = status
            }
        }
        if let baseline = object["baseline"] as? [String: Any] {
            trial.testCount = baseline["testCount"] as? Int ?? 0
            trial.baselineSeconds = baseline["durationSeconds"] as? Double ?? 0
        }
        if let durations = object["durations"] as? [String: Any] {
            let phase = durations["mutantPhaseSeconds"] as? Double
            let count = durations["executedMutants"] as? Int ?? 0
            let startup = (durations["breakdown"] as? [String: Any])?["startupRunSeconds"] as? Double ?? 0
            trial.phaseSeconds = phase
            trial.executed = count
            trial.startupSeconds = startup
            trial.finalBaselineSeconds = durations["finalBaselineSeconds"] as? Double ?? 0
            if let phase, count > 0 { trial.secondsPerMutant = max(phase - startup, 0) / Double(count) }
            if let confirmation = durations["confirmation"] as? [String: Any] {
                trial.restoredStates = confirmation["restoredStates"] as? Int
                trial.restoreFallbacks = confirmation["restoreFallbacks"] as? Int
            }
        }
        for warning in object["warnings"] as? [[String: Any]] ?? [] {
            if let kind = warning["kind"] as? String { trial.warnings[kind] = warning["message"] as? String ?? "" }
        }
        return trial
    }

    // MARK: The command

    /// The prefix of init's own work directories (`<prefix><pid>`), in the temporary directory or the `--work-dir`.
    static let workPrefix = "\(ToolInfo.name)-init-"

    /// Removes the work directories of init processes that no longer exist (an init that was killed).
    static func removeOrphanWork(in base: URL) {
        for name in (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? [] where name.hasPrefix(workPrefix) {
            guard let pid = Int32(name.dropFirst(workPrefix.count)), pid != getpid(), !(kill(pid, 0) == 0 || errno == EPERM) else { continue }
            let directory = base.appendingPathComponent(name)
            PackageLockFiles.remove(derivedData: directory.appendingPathComponent("DerivedData"))
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// Empties init's work directory: all of it after a success; after a failure, all but the logs that the messages
    /// name (the build and the copies of the project took 16 GB on a large app).
    static func cleanUp(_ work: URL, keepLogs: Bool) {
        PackageLockFiles.remove(derivedData: work.appendingPathComponent("DerivedData"))
        guard keepLogs else {
            try? FileManager.default.removeItem(at: work)
            return
        }
        for name in (try? FileManager.default.contentsOfDirectory(atPath: work.path)) ?? [] where !name.hasSuffix(".log") {
            try? FileManager.default.removeItem(at: work.appendingPathComponent(name))
        }
    }

    /// Runs `init`. Returns the exit code: 0 written (or shown with --dry-run), 1 the file exists and differs (shown;
    /// --force writes), 2 the project could not be tried.
    public static func perform(_ options: Options, say: (String) -> Void) throws -> Int32 {
        let container = try container(options)
        let scheme = try scheme(options, container: container)
        if let workDir = options.workDir,
           let refusal = WorkDirectoryGuard.refusal(directory: resolved(workDir, options), root: options.root, copyRoot: nil,
                                                    ignoredByGit: { WorkDirectoryGuard.gitIgnores($0, in: options.root) }) {
            throw Failure(refusal.description)
        }
        var destination = options.destination
        var isSimulator = destination.map { !$0.contains("platform=macOS") } ?? false
        if destination == nil {
            if container.kind == "package" {
                destination = "platform=macOS"
            } else if let booted = bootedSimulator() {
                destination = "id=\(booted.udid)"
                isSimulator = true
                say("simulator: \(booted.name) (\(booted.udid)), booted")
            } else {
                throw Failure("no booted iOS simulator. Boot one (`xcrun simctl boot <UDID>`; `xcrun simctl list devices available` lists them) or give --destination")
            }
        }
        var facts = Facts(container: container, scheme: scheme, destination: destination ?? "platform=macOS", isSimulator: isSimulator)
        facts.defaultBranch = defaultBranch(root: options.root)
        facts.buildArguments = options.buildArguments
        facts.packageCache = options.packageCache.map { forFile($0, options) }
        facts.workDir = options.workDir.map { forFile($0, options) }
        facts.impactMap = impactMapPath(root: options.root) { WorkDirectoryGuard.gitIgnores($0, in: options.root) }
        let simulator = facts.isSimulator ? SimulatorCheck.simulator(forDestination: facts.destination) : nil
        if let simulator, options.destination == nil || facts.destination.hasPrefix("id=") {
            let json = SimulatorWorkers.listJSON()
            facts.fileDestination = json.flatMap { SimulatorCheck.destinationByName(udid: simulator.udid, simctlJSON: $0) }
        }
        // The trials read the project's config file for what to mutate, not for how to run (that is what is being chosen)
        var mutationSettings: [String: Any]
        do {
            mutationSettings = try settings(target: options.configFile, legacy: options.legacyConfig)
        } catch {
            throw Failure("\(error)")
        }
        mutationSettings["run"] = nil
        mutationSettings["profiles"] = nil
        let sample = try sampleFiles(options, exclude: mutationSettings["exclude"] as? [String] ?? [])

        // Init's work: in the work directory given, else in the temporary directory
        let base = options.workDir.map { resolved($0, options) } ?? FileManager.default.temporaryDirectory
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        // The work directory given is the runs' too: marked as the tool's own and locked, as a run does (so that
        // `clean` or a run does not remove it under the trials)
        var workLock: WorkDirectoryLock?
        if options.workDir != nil {
            do {
                workLock = try WorkDirectoryLock.acquire(base, purpose: "init")
            } catch let busy as WorkDirectoryLock.Busy {
                throw Failure(busy.description)
            }
            WorkDirectoryInfo.write(to: base, root: options.root)
        }
        defer { workLock?.release() }
        removeOrphanWork(in: base)
        let removed = SimulatorWorkers.removeOrphans()
        if !removed.isEmpty { say("removed \(removed.count) simulators left by earlier runs of \(ToolInfo.name): \(removed.joined(separator: ", "))") }
        let work = base.appendingPathComponent("\(workPrefix)\(getpid())")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        var succeeded = false
        // After a failure only the logs that the messages name are kept; the next init removes them
        defer { cleanUp(work, keepLogs: !succeeded) }
        var created: String?
        defer { if let created { SimulatorWorkers.delete(created) } }
        do {
            say("building for testing (\(container.kind) \(container.path), scheme \(scheme))...")
            try inspectBuild(options, facts: &facts, derivedData: work.appendingPathComponent("DerivedData"), log: work.appendingPathComponent("build.log"))
            say("unit-test targets: \(facts.unitTargets.joined(separator: ", "))\(facts.uiTargets.isEmpty ? "" : "; UI test targets left out: \(facts.uiTargets.joined(separator: ", "))")\(facts.configurations.count > 1 ? "; test-plan configurations: \(facts.configurations.joined(separator: ", "))" : "")")

            // The trials run on a simulator of their own (putting the keychain back must not touch the user's), with
            // the privacy settings of the user's simulator for the app, as the worker simulators of a run get them
            var trialFacts = facts
            if let simulator {
                if let device = try? SimulatorWorkers.create(count: 1, like: simulator.udid).first {
                    created = device.udid
                    trialFacts.destination = "id=\(device.udid)"
                    let hosts = hostBundleIdentifiers(derivedData: work.appendingPathComponent("DerivedData"))
                    facts.workerPrivacyProblem = SimulatorWorkers.copyPrivacy(from: simulator.udid, to: [device.udid], bundles: hosts)
                    if let problem = facts.workerPrivacyProblem { say("the privacy settings of \(simulator.name) could not all be given to another simulator: \(problem)") }
                } else {
                    facts.workerPrivacyProblem = "no simulator like \(simulator.name) could be created"
                }
            }
            try Data(json(mutationSettings).utf8).write(to: work.appendingPathComponent("config.json"))
            say("the sample of the trials: \(options.sample) mutants of \(sample.scope)")
            say("trial 1: \(options.sample) mutants in the default mode (one process per mutant)...")
            let plain = trial(options, facts: trialFacts, files: sample.files, extra: [], work: work, label: "plain")
            guard plain.exitCode == 0 || plain.exitCode == 3, plain.testCount > 0 else {
                let tail = ((try? String(contentsOf: work.appendingPathComponent("plain.log"), encoding: .utf8)) ?? "").split(separator: "\n").suffix(5).joined(separator: "\n  ")
                throw Failure("the trial run did not complete (exit code \(plain.exitCode)); the tests must pass without mutants first (log: \(work.appendingPathComponent("plain.log").path)):\n  \(tail)")
            }
            say(String(format: "  %d tests in %.0f s; %d mutants judged, %d run%@", plain.testCount, plain.baselineSeconds, plain.statuses.count, plain.executed,
                       plain.secondsPerMutant.map { String(format: ", %.1f s each", $0) } ?? ""))
            var fastOptions = ["--select-tests", "reach", "--shared-process"]
            if facts.isSimulator && facts.appHosted { fastOptions += ["--confirm-kills", "restore"] }
            say("trial 2: the same mutants with \(fastOptions.joined(separator: " "))...")
            let fast = trial(options, facts: trialFacts, files: sample.files, extra: fastOptions, work: work, label: "fast")
            say(fast.secondsPerMutant.map { String(format: "  %.1f s per mutant (without the runs without mutants at the start of shared processes, %.0f s)", $0, fast.startupSeconds) } ?? "  no time per mutant")

            let recommendation = recommend(facts: facts, plain: plain, fast: fast, fastOptions: fastOptions)
            for reason in recommendation.reasons { say("  " + reason) }
            say(recommendation.estimate)
            let existing = try? ConfigFile.object(at: options.configFile)
            let output: Output
            do {
                output = try Self.output(recommendation, target: options.configFile, legacy: options.legacyConfig)
            } catch {
                throw Failure("\(error)")
            }
            succeeded = true
            let documentation = "The keys: \(ConfigFile.runOptionsDocumentation)"
            if options.dryRun {
                if let old = output.replaces { say("this would be written to \(output.file.path), with the settings of \(old.lastPathComponent), which it would replace (with --force)") }
                print(output.text, terminator: "")
                return 0
            }
            if let old = output.replaces, !options.force {
                let legacy = (try? ConfigFile.object(at: old)) ?? [:]
                let moved = legacy.keys.filter { $0 != "run" && $0 != "profiles" && !$0.hasPrefix("_") }.sorted()
                let profiles = (legacy["profiles"] as? [String: Any])?.keys.sorted() ?? []
                let replaced = (legacy["run"] != nil ? ["run"] : []) + (profiles.isEmpty ? [] : ["profiles \(profiles.joined(separator: ", "))"])
                say("\(old.path) is the config file of versions up to 0.14. init writes \(output.file.lastPathComponent) instead, with its settings (\(moved.joined(separator: ", ").nonEmpty ?? "none")) carried over\(replaced.isEmpty ? "" : "; its run options (\(replaced.joined(separator: "; "))) are replaced by those of init"), and removes \(old.lastPathComponent), so that there is one config file. Nothing was written. What init would write:")
                print(output.text, terminator: "")
                say("Write it with --force (\(old.lastPathComponent) is removed then; git still has it), or keep the JSON file with --config \(old.lastPathComponent). \(documentation)")
                return 1
            }
            if let existing, existing["run"] != nil || existing["profiles"] != nil, !options.force {
                say("\(options.configFile.path) already has run options; nothing was written. What init would write:")
                print(output.text, terminator: "")
                say("Write it with --force (the other keys of the file\(ConfigFile.format(of: output.file) == .yaml ? " and its comments" : "") are kept). \(documentation)")
                return 1
            }
            try Data(output.text.utf8).write(to: output.file)
            if let old = output.replaces {
                try FileManager.default.removeItem(at: old)
                say("removed \(old.path): its settings are in \(output.file.lastPathComponent) now")
            }
            if output.commentsLost { say("the comments of \(output.file.lastPathComponent) could not be kept: it was written anew from its values") }
            say("written: \(output.file.path). Run: \(ToolInfo.name) run --profile pr (or --profile nightly). \(documentation)")
            return 0
        } catch {
            // A full disk shows as a build that fails, a trial that does not complete or a file that cannot be written
            // The build's log is xcodebuild's; of the trials' logs only the lines that report errors are read
            let build = (try? String(contentsOf: work.appendingPathComponent("build.log"), encoding: .utf8)) ?? ""
            let trials = ["plain.log", "fast.log"].compactMap { try? String(contentsOf: work.appendingPathComponent($0), encoding: .utf8) }
            if saysDiskFull("\(error)") || saysDiskFull(build, errorLinesOnly: true) || trials.contains(where: { saysDiskFull($0, errorLinesOnly: true) }) {
                let used = WorkDirectoryInfo.formatSize(WorkDirectoryInfo.size(of: work))
                throw Failure("the disk is full (No space left on device; \(freeSpace(at: work).map { "\($0) free" } ?? "free space unknown") on the volume of \(base.path)). init needs room for a build and two work copies of the project (\(used) when it stopped; removed now). Free some space, or give --work-dir on a volume with more room. What failed: \(error)")
            }
            throw error
        }
    }

    static func hostBundleIdentifiers(derivedData: URL) -> [String] {
        let products = derivedData.appendingPathComponent("Build/Products")
        guard let xctestrun = ((try? FileManager.default.contentsOfDirectory(at: products, includingPropertiesForKeys: nil)) ?? []).first(where: { $0.pathExtension == "xctestrun" }) else { return [] }
        return Xcode.hostBundleIdentifiers(xctestrun: xctestrun)
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
