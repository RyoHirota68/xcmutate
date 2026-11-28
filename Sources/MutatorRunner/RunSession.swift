import Foundation
import MutatorCore

/// Configuration of `run`.
public struct RunConfiguration: Sendable {
    /// Directory to turn into a work copy (default: the git root).
    public var root: URL
    /// Target files (paths relative to root).
    public var files: [String]
    /// Line ranges of the `--since` diff (path relative to root → line ranges). If nil, whole files.
    public var changedLines: [String: [ClosedRange<Int>]]?
    /// Stable keys from `--only`.
    public var onlyKeys: [String]
    public var xcode: XcodeOptions
    /// Shell command run in the work copy before the build (XcodeGen, etc.).
    public var prepareCommand: String?
    public var workDirectory: URL
    public var timeoutFactor: Double
    public var timeoutConstant: Double
    public var baselineTimeout: Double
    public var maxRebuilds: Int
    public var keepResultBundles: Bool
    public var generatorOptions: GeneratorOptions
    /// `--select-tests auto`: finds the tests corresponding to the target files and passes them to `-only-testing`.
    public var selectTestsAutomatically: Bool = false
    /// `--select-tests impact --impact-map <file>`: the tests are the suites that the map says ran the files changed
    /// since its commit, and the suites of changed test files (`ImpactMap`); reach narrowing applies within them.
    public var impactMap: URL?
    /// `--write-impact-map <file>`: write the map of this run's baseline (needs `--select-tests reach`).
    public var writeImpactMap: URL?
    /// `--select-tests reach`: records per-test reach in the baseline and, for each mutant, runs only the suites of
    /// the tests that reached it.
    public var selectTestsByReach: Bool = false
    /// Accepted mutants (xcmutate.accepted.json).
    public var accepted: AcceptedFile = AcceptedFile()
    /// SPM package cache (a `SourcePackages` directory). Cloned if DerivedData does not have one.
    public var packageCache: URL?
    /// Maximum number of builds when bisecting compile errors that cannot be identified from diagnostics.
    public var maxBisectBuilds: Int = 16
    /// The unit copied into the work copy (the git repository root). If nil, `root`. `root` must be inside it.
    /// Lets projects that reference things outside `root` by relative path (such as `../Shared/Base.xcconfig`) be built
    /// in the work copy as long as they are inside the same repository.
    public var copyRoot: URL?
    /// Continues from the record of the previous run (`<work-dir>/journal/observations.jsonl`).
    public var resume = false
    /// Warnings found by the caller (CLI) (unknown keys in the config file, files excluded although they are in the diff, etc.).
    public var initialWarnings: [RunWarning] = []
    /// Files excluded from the targets (listed in the report).
    public var excluded = RunReport.Excluded()
    /// Caller-side configuration strings added to the record fingerprint (contents of the config file and the accepted file, etc.).
    public var fingerprintParts: [String] = []
    /// Files left out of the record fingerprint (output destinations of the reports this tool writes; absolute paths).
    public var fingerprintIgnoredPaths: Set<String> = []
    /// `--shared-process`: run several mutants in one test process where that can be done without changing verdicts.
    public var sharedProcess = false
    /// `--shared-process auto`: decide after the baseline whether shared processes are expected to save time
    /// (`SharedProcessChoice`); `sharedProcess` is false then.
    public var sharedProcessAuto = false
    /// False (`--no-narrow-gate`): both runs without mutants at the start of a shared process run the whole selection.
    /// True: with narrowed tests, the second runs only the suites of the process's mutants.
    public var narrowGate = true
    /// With shared processes: a mutant run by itself against all selected tests runs in a process with the tool's
    /// driver and stops at its first failing test (`--no-stop-at-first-failure`: false, every such run goes to the end
    /// under `xcodebuild`).
    public var stopAtFirstFailure = true
    /// `--stop-when-gate-decided`: the requested gates; the run stops when their result can no longer change.
    public var stopWhenGateDecided: Gate?
    /// The run options that came from the config file (for the report).
    public var settings: RunReport.Settings?
    /// `--trust-shared-survivors`: do not run again, alone, the mutants whose tests passed in a shared process.
    public var trustSharedSurvivors = false
    /// `--workers`: number of test destinations that run mutants at the same time.
    public var workers = 1
    /// `--no-direct-launch` (false): with `--shared-process`, let `xcodebuild` start every test process. By default
    /// the tool starts the test host itself for shared processes and for the confirmation of survivors, which is
    /// faster; `xcodebuild` still starts every run that decides Killed alone, Crash or Timeout.
    public var directLaunch = true
    /// `--reuse`: take over the Killed of an earlier run for mutants whose result cannot have changed (`Reuse`).
    public var reuse = false
    /// Destinations after the first (`--destination` given more than once). Workers beyond these are simulators
    /// that the tool creates like the first destination and deletes at the end.
    public var additionalDestinations: [String] = []
    /// `--confirm-kills`: when a failing run is taken as the mutant's doing.
    public var confirmKills = KillConfirmation.auto
    /// With `--select-tests reach` (off with `--no-recheck-survivors`): a mutant that survives the tests that reach it is run once
    /// more against the whole selection before it is reported as Survived.
    public var recheckSurvivors = false
    /// `--max-mutants`: at most this many mutants are examined, chosen by their stable keys (`MutantSample`).
    public var maxMutants: Int?
    /// `--time-limit`: seconds after which the run is cut short and reports what it has, and the text the user gave.
    public var timeLimit: Double?
    public var timeLimitText: String?
    /// The files to mutate were named on the command line (the report then says `scope: files`, not `all`).
    public var filesWereGiven = false

    public init(root: URL, files: [String], changedLines: [String: [ClosedRange<Int>]]?, onlyKeys: [String],
                xcode: XcodeOptions, prepareCommand: String?, workDirectory: URL,
                timeoutFactor: Double = 3, timeoutConstant: Double = 30, baselineTimeout: Double = 1800,
                maxRebuilds: Int = 5, keepResultBundles: Bool = false,
                generatorOptions: GeneratorOptions = GeneratorOptions()) {
        self.root = root
        self.files = files
        self.changedLines = changedLines
        self.onlyKeys = onlyKeys
        self.xcode = xcode
        self.prepareCommand = prepareCommand
        self.workDirectory = workDirectory
        self.timeoutFactor = timeoutFactor
        self.timeoutConstant = timeoutConstant
        self.baselineTimeout = baselineTimeout
        self.maxRebuilds = maxRebuilds
        self.keepResultBundles = keepResultBundles
        self.generatorOptions = generatorOptions
    }
}

/// Which stage it stopped at (with the location of the log showing the cause).
public enum RunError: Error, CustomStringConvertible {
    case stage(String, String, log: String?)
    /// Interrupted before any result was produced (during the build or the baseline).
    case interrupted

    public var description: String {
        switch self {
        case let .stage(stage, message, log):
            "[\(stage)] \(message)" + (log.map { "\n  log: \($0)" } ?? "")
        case .interrupted:
            "interrupted before any mutant was run"
        }
    }

    /// `[baseline]`: tests fail without any mutant (a problem on the project side).
    public var isBaselineFailure: Bool {
        if case let .stage(stage, _, _) = self { return stage == "baseline" }
        return false
    }
}

/// Layout inside the work directory.
public struct RunLayout: Sendable {
    /// The unit copied into the work copy (the git repository root, or `root`).
    public let copyRoot: URL
    /// The work copy (`<work-dir>/src`; a copy of `copyRoot`).
    public let sourceDirectory: URL
    /// `root` inside the work copy. Target file paths, `--project` and the like are relative to this.
    public let rootInCopy: URL

    public init(root: URL, copyRoot: URL?, workDirectory: URL) {
        sourceDirectory = workDirectory.appendingPathComponent("src")
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        if let copyRoot {
            let copyPath = copyRoot.standardizedFileURL.resolvingSymlinksInPath().path
            if rootPath == copyPath {
                self.copyRoot = copyRoot
                rootInCopy = sourceDirectory
                return
            }
            if rootPath.hasPrefix(copyPath + "/") {
                self.copyRoot = copyRoot
                rootInCopy = sourceDirectory.appendingPathComponent(String(rootPath.dropFirst(copyPath.count + 1)))
                return
            }
        }
        self.copyRoot = root
        rootInCopy = sourceDirectory
    }
}

/// Prints progress to standard error.
func progress(_ message: String) {
    RunProgress.printed(message)
    guard !ProgressOutput.silent else { return }
    FileHandle.standardError.write(Data("\(ToolInfo.name): \(message)\n".utf8))
}

enum ProgressOutput {
    /// True inside the tool's own unit tests (the test process has XCTest loaded; the tool's executable never has):
    /// the lines that tests of the executor make the tool print (warnings they provoke on purpose among them) would
    /// otherwise be mixed into the output of `swift test` and read like failures.
    static let silent: Bool = NSClassFromString("XCTestCase") != nil && ProcessInfo.processInfo.environment["XCMUTATE_TEST_PROGRESS"] == nil
}

/// Performs "generation → work copy → instrumentation → build-for-testing (rebuilding after removing what does not compile) →
/// baseline (recording reach) → canary → test-without-building per mutant".
public final class RunSession {
    /// Environment variable that `--prepare` commands receive: the original `--root` (the command itself runs in the copy).
    public static let originalRootEnvironmentVariable = ToolNaming.environmentPrefix + "ORIGINAL_ROOT"

    let config: RunConfiguration
    let layout: RunLayout
    /// `root` inside the work copy (where the target files are rewritten).
    let sourceDirectory: URL
    let journal: Journal
    let derivedData: URL
    let resultsDirectory: URL
    let tracesDirectory: URL
    let logsDirectory: URL
    private let runCountLock = NSLock()
    private var runCounts: [Int: Int] = [:]
    let sessionsDirectory: URL
    /// Killed results kept for later runs (`--reuse`).
    let reuseStoreURL: URL
    let xcode: Xcode
    /// The environment variables of this run's embedding (`Instrumenter.EnvironmentNames`).
    let names: Instrumenter.EnvironmentNames
    /// The text of each file as last instrumented, and the positions of the mutated branches (used to identify compile errors).
    var branchMaps: [String: (text: String, branches: [Int: ByteRange])] = [:]

    public init(config: RunConfiguration) {
        self.config = config
        let work = config.workDirectory
        layout = RunLayout(root: config.root, copyRoot: config.copyRoot, workDirectory: work)
        sourceDirectory = layout.rootInCopy
        journal = Journal(url: work.appendingPathComponent("journal/observations.jsonl"))
        derivedData = work.appendingPathComponent("DerivedData")
        resultsDirectory = work.appendingPathComponent("results")
        tracesDirectory = work.appendingPathComponent("traces")
        logsDirectory = work.appendingPathComponent("logs")
        sessionsDirectory = work.appendingPathComponent("shared-process")
        reuseStoreURL = work.appendingPathComponent("reuse/killed.json")
        xcode = Xcode(options: config.xcode, derivedData: derivedData)
        names = Instrumenter.EnvironmentNames(token: Instrumenter.EnvironmentNames.token(
            forWorkDirectory: work.standardizedFileURL.resolvingSymlinksInPath().path))
    }

    public func run() throws -> RunReport {
        defer { journal.close() }
        let totalStart = Date()
        let formatter = ISO8601DateFormatter()
        var durations = RunDurations()
        var warnings: [RunWarning] = config.initialWarnings
        let fm = FileManager.default
        // Nothing is deleted or created before the work directory is known to be the tool's own and not in use
        if let refusal = WorkDirectoryGuard.refusal(directory: config.workDirectory, root: config.root, copyRoot: config.copyRoot,
                                                    ignoredByGit: { WorkDirectoryGuard.gitIgnores($0, in: self.config.copyRoot ?? self.config.root) }) {
            throw RunError.stage("work-dir", refusal.description, log: nil)
        }
        let workLock: WorkDirectoryLock
        do {
            workLock = try WorkDirectoryLock.acquire(config.workDirectory, purpose: "run")
        } catch let busy as WorkDirectoryLock.Busy {
            throw RunError.stage("work-dir", busy.description, log: nil)
        }
        defer { workLock.release() }
        // xcodebuild leaves lock files for this DerivedData directory in the temporary directory (removed while the
        // work directory is still locked, so that no other run is building there)
        defer { PackageLockFiles.remove(derivedData: derivedData) }
        // --workers with a simulator by name that is not one simulator here: not a Mac, where the workers would share
        // the destination, but a destination to name better (checked before the build, not after the baseline)
        if config.workers > 1 + config.additionalDestinations.count, let json = SimulatorWorkers.listJSON(),
           let refusal = SimulatorCheck.workersRefusal(forDestination: config.xcode.destination, simctlJSON: json) {
            throw RunError.stage("workers", refusal, log: nil)
        }
        WorkDirectoryInfo.write(to: config.workDirectory, root: config.root)
        // The logs of the run before this one are kept, one generation of them, in `logs-previous`: a log that is
        // looked for only after the next run has started was gone before (the one run in which a crashing mutant
        // became a Timeout could not be explained for that reason). `clean` removes both with the work directory.
        let previousLogs = logsDirectory.deletingLastPathComponent().appendingPathComponent("logs-previous")
        if (try? fm.contentsOfDirectory(atPath: logsDirectory.path))?.isEmpty == false {
            try? fm.removeItem(at: previousLogs)
            try? fm.moveItem(at: logsDirectory, to: previousLogs)
        }
        for dir in [resultsDirectory, tracesDirectory, logsDirectory] {
            try? fm.removeItem(at: dir)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        // A simulator that is not booted is booted and shut down by xcodebuild for every test run. Only warn; never boot it here.
        if let message = SimulatorCheck.warning(forDestination: config.xcode.destination) { progress(message) }

        // 1. Generation (only reads the sources in the user's working tree; does not rewrite them)
        var start = Date()
        let processor = FileProcessor(options: config.generatorOptions)
        var sources: [String: String] = [:]
        var allMutants: [Mutant] = []
        var ignored: [IgnoredMutant] = []
        var skipped: [String: String] = [:]
        var allKeys: Set<String> = []
        var testSelection: RunReport.TestSelection?
        var acceptance: RunReport.Acceptance?
        var nextID = 0
        for file in config.files {
            let source: String
            do {
                source = try SourceText.read(config.root.appendingPathComponent(file))
            } catch let error as SourceText.NotUTF8 {
                throw RunError.stage("read", error.description, log: nil)
            } catch {
                throw RunError.stage("read", "\(file) cannot be read: \(error.localizedDescription)", log: nil)
            }
            sources[file] = source
            let lines = config.changedLines.map { $0[file] ?? [] }
            let result = processor.process(source: source, file: file, firstID: nextID, changedLines: lines)
            if let reason = result.skippedReason {
                skipped[file] = reason
                // Never dropped silently: the file is named on standard error and in every report, and a gate does not pass
                let message = "\(file) was not mutated: \(Self.skipExplanation(reason))"
                progress("warning: " + message)
                warnings.append(RunWarning(kind: "skippedFile", message: message, file: file))
            }
            for warning in result.warnings {
                // On standard error too: a comment that disables nothing is something to see before the run, not after it
                progress("warning: \(file):\(warning.line): \(warning.message)")
                warnings.append(RunWarning(kind: "disableComment", message: "\(file):\(warning.line): \(warning.message)", file: file))
            }
            if lines == nil {
                allKeys.formUnion(result.mutants.map(\.key))
            } else {
                allKeys.formUnion(processor.generator.generate(source: source, filePath: file).mutants.map(\.key))
            }
            nextID += result.mutants.count
            allMutants += result.mutants
            ignored += result.ignored
        }
        var selected = allMutants
        if !config.onlyKeys.isEmpty {
            let keys = Set(config.onlyKeys)
            selected = allMutants.filter { keys.contains($0.key) }
            let unknown = keys.subtracting(selected.map(\.key)).sorted()
            // A key that names nothing is a mistake of the caller (a typing error, or the code changed and with it the key).
            // Reporting "0 mutants, nothing survived" would look like success
            guard !selected.isEmpty else {
                throw RunError.stage("only", "none of the \(keys.count) keys given with --only names a mutant of this version of the sources (first: \(unknown.first ?? "")). A key changes when the code it names changes: run again without --only and take the keys from that report", log: nil)
            }
            for key in unknown {
                progress("warning: --only: no mutant with key \(key)")
                warnings.append(RunWarning(kind: "unknownKey", message: "--only: no mutant with key \(key)", key: key))
            }
            // The numbers side by side: a key that never reached the tool (a list cut short by the shell) shows here
            progress("--only: \(config.onlyKeys.count) keys given\(keys.count < config.onlyKeys.count ? " (\(keys.count) different ones)" : ""), \(selected.count) mutants selected")
        }
        var sampling: RunReport.Sampling?
        if let limit = config.maxMutants, selected.count > limit {
            // Which mutants: decided by their stable keys alone, so that the same sources give the same sample on every
            // machine and a change elsewhere in the code moves few mutants in or out of it
            let chosen = MutantSample.choose(selected.map(\.key), limit: limit)
            sampling = RunReport.Sampling(limit: limit, candidates: selected.count, omittedKeys: selected.map(\.key).filter { !chosen.contains($0) })
            let message = "--max-mutants \(limit): \(limit) of \(selected.count) mutants are examined, chosen by their stable keys; the other \(selected.count - limit) are not in this report. The score is that of the sample, and a gate that passes says nothing about the mutants that were left out."
            selected = selected.filter { chosen.contains($0.key) }
            progress(message)
            warnings.append(RunWarning(kind: "sampled", message: message))
        }
        durations.generationSeconds = Date().timeIntervalSince(start)
        progress("\(selected.count) mutant\(selected.count == 1 ? "" : "s") in \(config.files.count) file\(config.files.count == 1 ? "" : "s") (\(ignored.count) ignored)")
        let timeLimit = config.timeLimit.map { TimeLimit(seconds: $0, describedAs: config.timeLimitText ?? "\(Int($0))s") }
        defer { timeLimit?.cancel() }
        /// The warning of a run that was cut short: by the time limit, or by a signal.
        func cutShort(_ what: String) -> RunWarning {
            if let decision = InterruptState.gateDecision {
                return RunWarning(kind: "gateDecided", message: "The gate's result was decided before every mutant had run (\(decision); --stop-when-gate-decided)\(what)")
            }
            return InterruptState.timeLimitReached
                ? RunWarning(kind: "timeLimit", message: "The time limit (--time-limit \(config.timeLimitText ?? "")) was reached\(what)")
                : RunWarning(kind: "interrupted", message: "The run was interrupted\(what)")
        }

        var results: [Int: MutantResult] = [:]
        func record(_ m: Mutant, _ status: MutantStatus, killedBy: [String] = [], duration: Double? = nil, attempts: Int = 0, detail: String? = nil) {
            var result = MutantResult(mutant: m, status: status, killedBy: killedBy, durationSeconds: duration, attempts: attempts, detail: detail)
            if status == .compileError, detail?.hasPrefix(MutantResult.collateralDetailPrefix) == true { result.collateral = true }
            results[m.id] = result
        }
        var interrupted = false
        var pending: [String] = []
        var resumedCount = 0
        var reuseSummary: RunReport.ReuseSummary?
        let commit = Self.commit(of: config.root)

        func makeReport(baseline: RunReport.Baseline?) -> RunReport {
            durations.totalSeconds = Date().timeIntervalSince(totalStart)
            var report = RunReport(
                scope: config.onlyKeys.isEmpty ? (config.changedLines == nil ? (config.filesWereGiven ? "files" : "all") : "diff") : "only",
                root: config.root.path, files: config.files, skippedFiles: skipped, baseline: baseline,
                durations: durations,
                results: selected.compactMap { results[$0.id] },
                // With --only, only the specified mutants are targeted, so the list of exclusions is not included
                ignored: config.onlyKeys.isEmpty ? ignored : [], warnings: warnings,
                testSelection: testSelection, acceptance: acceptance)
            report.startedAt = formatter.string(from: totalStart)
            report.finishedAt = formatter.string(from: Date())
            report.commit = commit
            report.interrupted = interrupted
            report.timeLimitReached = interrupted && InterruptState.timeLimitReached ? true : nil
            report.gateDecidedEarly = interrupted && InterruptState.gateDecision != nil ? true : nil
            report.gateDecision = interrupted ? InterruptState.gateDecision : nil
            report.sampling = sampling
            report.pendingKeys = pending
            report.resumedCount = resumedCount
            report.reuse = reuseSummary
            report.settings = config.settings
            report.excluded = config.excluded
            return report
        }

        if selected.isEmpty {
            progress("no mutants to run")
            return makeReport(baseline: nil)
        }

        // Record (journal): start anew, or continue from the previous run with --resume
        let fingerprint = RunFingerprint.compute(copyRoot: layout.copyRoot, parts: fingerprintParts(selected), ignoring: config.fingerprintIgnoredPaths)
        let fingerprintComponents = RunFingerprint.components(copyRoot: layout.copyRoot, parts: fingerprintParts(selected), ignoring: config.fingerprintIgnoredPaths)
        if config.resume {
            guard journal.load(), let header = journal.header else {
                throw RunError.stage("resume", "no journal of an earlier run in \(journal.url.path); run without --resume", log: nil)
            }
            guard header.fingerprint == fingerprint else {
                let changed = RunFingerprint.differences(earlier: header.components, now: fingerprintComponents).map { "What changed: \($0). " } ?? ""
                throw RunError.stage("resume", "the sources, the options or the tool version changed since the run that was started at \(header.startedAt) (tool \(header.toolVersion)); its results cannot be continued. \(changed)Run without --resume, or with the same options and sources as then", log: nil)
            }
            progress("resuming the run started at \(header.startedAt): \(journal.observations.count) mutants already observed, \(journal.compileErrors.count) known compile errors")
        } else {
            // A run that was stopped before its end left results that --resume would use; starting anew discards them
            let earlier = Journal(url: journal.url)
            if earlier.load(), let header = earlier.header, header.fingerprint == fingerprint, !earlier.finished, !earlier.observations.isEmpty {
                progress("note: the run started at \(header.startedAt) with the same sources and options did not finish; its \(earlier.observations.count) results are discarded now. --resume would have continued from them")
            }
            try journal.start(fingerprint: fingerprint, components: fingerprintComponents)
        }
        func stopIfInterrupted() throws {
            if InterruptState.isInterrupted { throw RunError.interrupted }
        }

        // 2. Work copy
        start = Date()
        RunProgress.begin("work copy")
        let copied = try WorkCopy.create(from: layout.copyRoot, to: layout.sourceDirectory)
        // Clone the SPM package cache into DerivedData's default location (SourcePackages).
        // Some projects have build scripts that reference `$BUILD_DIR/../../SourcePackages`, so this is
        // more reliable than pointing elsewhere with -clonedSourcePackagesDirPath.
        if let cache = config.packageCache {
            let target = derivedData.appendingPathComponent("SourcePackages")
            if !FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.createDirectory(at: derivedData, withIntermediateDirectories: true)
                let log = logsDirectory.appendingPathComponent("package-cache.log")
                let outcome = try Subprocess.run(["/bin/cp", "-cR", cache.path, target.path], logPath: log.path)
                guard outcome.status == 0 else {
                    throw RunError.stage("prepare", "failed to clone the package cache \(cache.path)", log: log.path)
                }
                progress("package cache cloned into \(target.path)")
            }
        }
        if let command = config.prepareCommand {
            let log = logsDirectory.appendingPathComponent("prepare.log")
            // Pass the original root in an environment variable so that ignored files (generated artifacts, secret settings) can be copied from their original location
            let outcome = try Subprocess.run(["/bin/sh", "-c", command], cwd: sourceDirectory.path,
                                             environment: [RunSession.originalRootEnvironmentVariable: config.root.path], logPath: log.path)
            try stopIfInterrupted()
            guard outcome.status == 0 else {
                throw RunError.stage("prepare", "prepare command failed with status \(outcome.status)", log: log.path)
            }
        }
        durations.copySeconds = Date().timeIntervalSince(start)
        progress("work copy: \(copied) files at \(layout.sourceDirectory.path)")

        // 3. Instrumentation and build. Mutants that do not compile are removed and the build is repeated
        var active = selected
        // Those known from the previous record not to compile are removed from the start
        if config.resume {
            for mutant in selected {
                if let detail = journal.compileErrors[mutant.key] { record(mutant, .compileError, detail: detail) }
            }
            active.removeAll { journal.compileErrors[$0.key] != nil }
        }
        func recordCompileError(_ mutant: Mutant, _ detail: String) throws {
            record(mutant, .compileError, detail: detail)
            try journal.record(compileError: mutant.key, detail: detail)
        }
        var xctestrun: URL?
        var otherXctestruns: [URL] = []
        let firstBuildStart = Date()
        var buildIndex = 0
        var rebuilds = 0
        var bisectBuilds = 0
        /// Instruments only the specified mutants and builds.
        func build(_ mutants: [Mutant], label: String) throws -> (ok: Bool, log: URL) {
            try instrument(mutants, sources: sources)
            let log = logsDirectory.appendingPathComponent("build-\(buildIndex).log")
            let bundle = resultsDirectory.appendingPathComponent("build-\(buildIndex).xcresult")
            buildIndex += 1
            RunProgress.begin("build", hint: { RunProgress.compiledFiles(inLog: log.path).map { "\($0) source files compiled so far" } })
            progress(label)
            let outcome = try xcode.buildForTesting(resultBundle: bundle, log: log)
            try stopIfInterrupted()
            durations.buildSeconds += outcome.duration
            durations.buildCount += 1
            if !config.keepResultBundles { try? FileManager.default.removeItem(at: bundle) }
            return (outcome.status == 0, log)
        }
        while true {
            let label = rebuilds == 0 ? "build-for-testing..." : "rebuilding without \(selected.count - active.count) mutants (attempt \(rebuilds))..."
            let (ok, log) = try build(active, label: label)
            if ok {
                (xctestrun, otherXctestruns) = xcode.xctestrun(since: firstBuildStart)
                break
            }
            guard rebuilds < config.maxRebuilds else {
                throw RunError.stage("build", "build still fails after \(rebuilds) rebuilds", log: log.path)
            }
            rebuilds += 1
            let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            let analysis = analyzeCompileErrors(in: text, mutants: active)
            if !analysis.culprits.isEmpty {
                for (mutant, diagnostic) in analysis.culprits { try recordCompileError(mutant, diagnostic) }
                let removed = Set(analysis.culprits.map(\.0.id))
                active.removeAll { removed.contains($0.id) }
                progress("excluded \(analysis.culprits.count) mutants that do not compile")
                continue
            }
            // No compiler error at all (a failure in a script phase, linking, signing, etc.): not caused by a mutant
            if CompilerDiagnostic.errors(inLog: text).isEmpty {
                throw RunError.stage("build", Self.buildFailureWithoutCompilerErrors(log: text) + missingFileHint(inLog: text), log: log.path)
            }
            // The diagnostics point neither at a mutant's line nor at a declaration containing a mutant (inside a macro expansion, another file, etc.): bisect to find them one by one
            let suspects = analysis.suspects.isEmpty ? active : analysis.suspects
            let suspectIDs = Set(suspects.map(\.id))
            let base = active.filter { !suspectIDs.contains($0.id) }
            progress("build errors do not point to a mutant; bisecting \(suspects.count) mutants...")
            guard bisectBuilds < config.maxBisectBuilds else {
                throw RunError.stage("build", "bisect build limit reached", log: log.path)
            }
            bisectBuilds += 1
            let (baseOK, baseLog) = try build(base, label: "bisect: building without the \(suspects.count) suspects...")
            guard baseOK else {
                let baseText = (try? String(contentsOf: baseLog, encoding: .utf8)) ?? ""
                // The compiler's own words first: with no mutant in the build, these are errors of the project
                let errors = CompilerDiagnostic.errors(inLog: baseText).prefix(5).map { "\n    \($0.path):\($0.line):\($0.column): \($0.message)" }.joined()
                throw RunError.stage("build", "build-for-testing fails without any of the suspected mutants: the project (product code or tests) does not build as it is\(errors.isEmpty ? "" : ":" + errors)" + missingFileHint(inLog: baseText), log: baseLog.path)
            }
            var limitReached = false
            let culprit = try CompileBisector.findCulprit(base: base, suspects: suspects) { candidate in
                guard bisectBuilds < config.maxBisectBuilds else { limitReached = true; return true }
                bisectBuilds += 1
                return try build(candidate, label: "bisect: \(candidate.count - base.count) of \(suspects.count) suspects...").ok
            }
            guard !limitReached, let culprit else {
                throw RunError.stage("build", "bisect build limit (\(config.maxBisectBuilds)) reached", log: log.path)
            }
            let first = CompilerDiagnostic.errors(inLog: text).first.map { "\($0.path):\($0.line): \($0.message)" } ?? "build failed"
            try recordCompileError(culprit, "found by bisection: \(first)")
            active.removeAll { $0.id == culprit.id }
            progress("excluded mutant #\(culprit.id) found by bisection")
        }
        guard let xctestrun else {
            throw RunError.stage("build", "build succeeded but no .xctestrun was found under \(derivedData.path)/Build/Products", log: nil)
        }

        // A scheme with several test plans builds one .xctestrun file per plan. Which one is used must not be a silent choice
        if !otherXctestruns.isEmpty, config.xcode.testPlan == nil {
            let message = "The build produced \(otherXctestruns.count + 1) .xctestrun files (one per test plan of the scheme). Used: \(xctestrun.lastPathComponent) (the one written last); not used: \(otherXctestruns.map(\.lastPathComponent).joined(separator: ", ")). Name the plan with --test-plan <name>."
            progress("warning: " + message)
            warnings.append(RunWarning(kind: "testPlanChoice", message: message))
        }

        // Test selection
        var runXcode = xcode
        if config.selectTestsAutomatically {
            let testPaths = (try? WorkCopy.listFiles(root: config.root))?.filter { $0.hasSuffix(".swift") && TestSelector.isTestPath($0) } ?? []
            let testFiles = testPaths.compactMap { path in
                (try? String(contentsOf: config.root.appendingPathComponent(path), encoding: .utf8)).map { (path: path, source: $0) }
            }
            let mutatedFiles = Array(Set(active.map(\.file))).sorted()
            let matches = TestSelector.matches(sourceFiles: mutatedFiles, testFiles: testFiles)
            var ids = TestSelector.identifiers(for: matches, targets: TestSelector.testTargets(xctestrun: xctestrun))
            // The tests found for one file say nothing about another file: when a mutated file has no test file of its
            // name, running its mutants against the tests of the other files would report them all as NotReached.
            // Then nothing is narrowed.
            let matched = Set(matches.map(\.sourceFile))
            let unmatched = mutatedFiles.filter { !matched.contains($0) }
            let rest = config.xcode.onlyTesting.isEmpty ? "all tests" : "the --only-testing tests"
            if ids != nil, !unmatched.isEmpty {
                ids = nil
                let message = "--select-tests auto found no test file named after \(unmatched.prefix(5).joined(separator: ", "))\(unmatched.count > 5 ? ", … (\(unmatched.count) files)" : ""); ran \(rest) for every mutant instead of the tests found for the other files"
                progress(message)
                warnings.append(RunWarning(kind: "testSelectionFallback", message: message))
            } else if let ids {
                runXcode.options.onlyTesting = Array(Set(ids + config.xcode.onlyTesting)).sorted()
                progress("selected tests: \(runXcode.options.onlyTesting.joined(separator: ", "))")
            } else {
                progress("no matching tests found; running \(rest)")
                warnings.append(RunWarning(kind: "testSelectionFallback", message: "--select-tests auto found no tests for the mutated files; ran \(rest) instead"))
            }
            testSelection = RunReport.TestSelection(mode: "auto", fallback: ids == nil, onlyTesting: runXcode.options.onlyTesting,
                                                    skipTesting: config.xcode.skipTesting.isEmpty ? nil : config.xcode.skipTesting, matches: matches,
                                                    unmatchedFiles: unmatched.isEmpty ? nil : unmatched)
        } else if let mapURL = config.impactMap {
            let summary = impactSelection(map: mapURL, xctestrun: xctestrun)
            if let suites = summary.suites {
                runXcode.options.onlyTesting = suites
                let message = "--select-tests impact: \(suites.count) suites chosen from the map of commit \(summary.commit.prefix(10)) for \(summary.changedFiles.count) changed files\(summary.newSuites.isEmpty ? "" : " (with suites the map does not know: \(summary.newSuites.joined(separator: ", ")))"). The results hold among these suites; a test outside them may still reach or detect a mutant (a full run is the reference)"
                progress(message)
                warnings.append(RunWarning(kind: "impactSelection", message: message))
            } else {
                let message = "--select-tests impact ran the whole selection: \(summary.reasons.prefix(5).joined(separator: "; "))\(summary.reasons.count > 5 ? "; … (\(summary.reasons.count) reasons)" : "")"
                progress(message)
                warnings.append(RunWarning(kind: "impactFallback", message: message))
            }
            testSelection = RunReport.TestSelection(mode: "impact", fallback: summary.suites == nil, onlyTesting: runXcode.options.onlyTesting,
                                                    skipTesting: config.xcode.skipTesting.isEmpty ? nil : config.xcode.skipTesting, matches: [])
            testSelection?.impact = .init(commit: summary.commit, changedFiles: summary.changedFiles, suites: summary.suites?.count,
                                          newSuites: summary.newSuites.isEmpty ? nil : summary.newSuites, fallbackReasons: summary.reasons.isEmpty ? nil : summary.reasons)
        } else {
            let manual = !config.xcode.onlyTesting.isEmpty || !config.xcode.skipTesting.isEmpty
            testSelection = RunReport.TestSelection(mode: manual ? "manual" : "all", fallback: false, onlyTesting: config.xcode.onlyTesting,
                                                    skipTesting: config.xcode.skipTesting.isEmpty ? nil : config.xcode.skipTesting, matches: [])
        }

        // If the test plan has several configurations, the tests run in every configuration for each mutant (the time is multiplied by the number of configurations)
        let configurations = Xcode.testConfigurationNames(xctestrun: xctestrun)
        if configurations.count > 1, !config.xcode.extraTestArguments.contains("-only-test-configuration") {
            progress("note: the test plan has \(configurations.count) configurations (\(configurations.joined(separator: ", "))); every mutant runs the tests once per configuration. If the code under test does not depend on them, --only-test-configuration <name> cuts the time per mutant accordingly")
        }

        // 4. Baseline: all tests must pass with all mutants off. The reached switches are recorded at the same time
        // --confirm-kills restore: the copy of the destination that later replaces the runs without mutants, taken
        // with the app installed and right before the baseline (whose pass is what the restored state stands for)
        var restore: SimulatorRestore?
        if config.confirmKills == .restore {
            switch prepareRestore(xctestrun: xctestrun, xcode: runXcode) {
            case let .success(made):
                restore = made
                progress("--confirm-kills restore: a copy of the app's containers and the simulator's keychain was taken; it replaces the runs without mutants after runs that did not pass")
            case let .failure(reason):
                let message = "--confirm-kills restore cannot be used (\(reason.description)); the tests are run without mutants after runs that did not pass, as with auto"
                progress(message)
                warnings.append(RunWarning(kind: "restoreUnavailable", message: message))
            }
        }
        let baselineTrace = tracesDirectory.appendingPathComponent("baseline.trace")
        let baselineLog = logsDirectory.appendingPathComponent("baseline.log")
        RunProgress.begin("baseline", hint: { RunProgress.endedTests(inLog: baselineLog.path).map { "\($0) tests ended so far" } })
        progress("baseline (all mutants off, recording reached switches\(config.selectTestsByReach ? " per test" : ""))...")
        let baselineBundle = resultsDirectory.appendingPathComponent("baseline.xcresult")
        let baselineOutcome = try runXcode.testWithoutBuilding(
            xctestrun: xctestrun,
            environment: ["TEST_RUNNER_\(names.trace)": baselineTrace.path]
                .merging(config.selectTestsByReach ? ["TEST_RUNNER_\(names.testTrace)": "1"] : [:]) { $1 },
            resultBundle: baselineBundle, log: baselineLog, timeout: config.baselineTimeout,
            // No limits that stop anything: only to learn how long the host takes until the first test starts, and
            // the longest time in which no test started or ended
            // (With --select-tests reach the test process writes its standard error, and so the lines of its tests,
            // into the trace file from the first switch on: that file is watched too.)
            watch: LogWatch(stallLimit: .infinity, alsoWatch: [baselineTrace.path]))
        try stopIfInterrupted()
        durations.baselineSeconds = baselineOutcome.duration
        let baselineSummary = TestSummary.load(baselineBundle)
        guard baselineOutcome.status == 0, !baselineOutcome.timedOut, let summary = baselineSummary, summary.failedTests == 0 else {
            let failures = baselineSummary?.failures.prefix(5).map { "\($0.test): \($0.message)" }.joined(separator: "\n    ") ?? ""
            throw RunError.stage("baseline", "tests fail with all mutants off (status \(baselineOutcome.status)\(baselineOutcome.timedOut ? ", timed out" : ""))" + (failures.isEmpty ? "" : "\n    " + failures), log: baselineLog.path)
        }
        // A run with 0 tests is not treated as "passed" (e.g. when --select-tests auto or the --only-testing arguments match no test)
        guard summary.totalTestCount > 0 else {
            throw RunError.stage("baseline", "no tests ran (check --only-testing / --select-tests / the test plan: the selection matched no test)", log: baselineLog.path)
        }
        let evidence = BaselineEvidence(testCount: summary.totalTestCount, passedTests: summary.passedTests, skippedTests: summary.skippedTests)
        if config.resume, let earlier = journal.baseline {
            guard earlier == evidence else {
                throw RunError.stage("resume", "the baseline ran \(evidence.testCount) tests (\(evidence.skippedTests) skipped); the run being resumed ran \(earlier.testCount) (\(earlier.skippedTests) skipped). Run without --resume", log: baselineLog.path)
            }
        } else {
            try journal.record(baseline: evidence)
        }
        // Per-test reach (--select-tests reach): build the per-mutant test selection from the record.
        // Where the attribution is uncertain, do not narrow (run everything)
        var selector: ReachSelector?
        let reached: Set<Int>
        if config.selectTestsByReach {
            let reach = TestReach.parse((try? String(decoding: Data(contentsOf: baselineTrace), as: UTF8.self)) ?? "")
            reached = reach.reached
            let made = ReachSelector(reach: reach, suites: TestSuiteInfo.load(baselineBundle) ?? [], totalTestCount: summary.totalTestCount)
            selector = made
            if let mapURL = config.writeImpactMap {
                if made.usable, let commit = Self.commit(of: config.root) {
                    let map = ImpactMap.make(reach: reach, suites: made.suites, mutants: active, commit: commit.sha, dirty: commit.dirty)
                    do {
                        try FileManager.default.createDirectory(at: mapURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try JSONEncoder.sortedPretty.encode(map).write(to: mapURL)
                        progress("impact map written: \(mapURL.path) (\(map.files.count) files, \(map.suites.count) suites, commit \(commit.sha.prefix(10))\(commit.dirty ? ", with uncommitted changes" : ""))")
                        if commit.dirty { warnings.append(RunWarning(kind: "impactMapDirty", message: "The impact map was written from a working tree with uncommitted changes; it is filed under commit \(commit.sha.prefix(10)), which does not hold them.")) }
                    } catch {
                        warnings.append(RunWarning(kind: "impactMapNotWritten", message: "The impact map could not be written to \(mapURL.path): \(error)"))
                    }
                } else {
                    warnings.append(RunWarning(kind: "impactMapNotWritten", message: "The impact map was not written: \(made.usable ? "the commit of the repository is not known" : "the tests that reach each mutant could not be attributed reliably")."))
                }
            }
            if !made.usable {
                warnings.append(RunWarning(kind: "reachSelectionUnavailable", message: "--select-tests reach: the tests that reach each mutant could not be attributed reliably (\(reach.reliable ? "the suites in the result bundle do not add up to the \(summary.totalTestCount) tests that ran" : "tests overlapped in the trace")); every mutant was run against the whole selection"))
            }
        } else {
            reached = Trace.read(baselineTrace).reached
        }
        let timeout = baselineOutcome.duration * config.timeoutFactor + config.timeoutConstant
        progress(String(format: "baseline passed: %d tests in %.1fs, %d of %d switches reached, timeout %.0fs",
                        summary.totalTestCount, baselineOutcome.duration, reached.intersection(active.map(\.id)).count, active.count, timeout))
        if reached.isEmpty {
            let selectionNote = (testSelection?.mode ?? "all") == "all" ? "" : " The tests were limited (\(testSelection?.mode ?? "")): the tests that exercise this code may not be among those that ran."
            warnings.append(RunWarning(kind: "noReach", message: "No switch was reached in the baseline: none of the tests that ran executes the mutated code.\(selectionNote) If they do exercise it, check that the test process can write the trace file (\(baselineTrace.path))."))
        }
        let baseline = RunReport.Baseline(durationSeconds: baselineOutcome.duration, testCount: summary.totalTestCount,
                                          passedTests: summary.passedTests, skippedTests: summary.skippedTests,
                                          reachedCount: reached.count, timeoutSeconds: timeout)

        // Results of earlier runs (--reuse): a reached mutant that an unchanged test killed in unchanged code is not run again
        var reuseState: ReuseState?
        var reuseEnvironment = ""
        var reuseDeclarations: [String: String] = [:]
        var reuseStore: ReuseStore?
        if config.reuse {
            let xcodeVersion = (try? Subprocess.capture(["xcodebuild", "-version"], timeout: 120)).map { $0.output.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
            reuseEnvironment = Reuse.environment(config: config, xcodeVersion: xcodeVersion)
            let state = ReuseState.scan(root: layout.copyRoot, ignoring: config.fingerprintIgnoredPaths)
            reuseState = state
            for mutant in selected {
                if let source = sources[mutant.file] { reuseDeclarations[mutant.key] = Reuse.declarationHash(source: source, mutant: mutant) }
            }
            reuseStore = ReuseStore.load(reuseStoreURL)
            let candidates = active.filter { reached.contains($0.id) }
            let candidateKeys = Set(candidates.map(\.key))
            let decision = Reuse.decide(store: reuseStore, environment: reuseEnvironment, state: state,
                                        declarations: reuseDeclarations.filter { candidateKeys.contains($0.key) },
                                        baselineTests: TestCaseList.load(baselineBundle))
            for mutant in candidates {
                guard let tests = decision.reusable[mutant.key], let entry = reuseStore?.entries[mutant.key] else { continue }
                var result = MutantResult(mutant: mutant, status: .killed, killedBy: tests, durationSeconds: nil, attempts: 0,
                                          detail: "not run: killed by \(tests.first ?? "a test") in the run of \(entry.recordedAt)\(entry.commit.map { " (commit \($0.prefix(12)))" } ?? ""); the product code and that test are unchanged (--reuse)")
                result.reused = true
                results[mutant.id] = result
            }
            let reusedIDs = Set(results.values.filter { $0.reused == true }.map(\.mutant.id))
            active.removeAll { reusedIDs.contains($0.id) }
            reuseSummary = RunReport.ReuseSummary(reusedCount: reusedIDs.count, refusal: decision.refusal, storedCount: 0)
            if let refusal = decision.refusal {
                progress("--reuse: nothing is reused: \(refusal)")
            } else {
                progress("--reuse: \(reusedIDs.count) of \(candidates.count) reached mutants take over the Killed of an earlier run; \(candidates.count - reusedIDs.count) are run")
            }
        }

        // 5. Per-mutant runs. Mutants that are not reached are not run
        // Workers: the destination given first, any further --destination, and simulators created for --workers
        var destinations = [config.xcode.destination] + config.additionalDestinations
        var createdSimulators: [SimulatorWorkers.Device] = []
        defer { createdSimulators.forEach { SimulatorWorkers.delete($0.udid) } }
        if config.workers > destinations.count {
            let missing = config.workers - destinations.count
            if let udid = SimulatorCheck.simulator(forDestination: config.xcode.destination)?.udid {
                let removed = SimulatorWorkers.removeOrphans()
                if !removed.isEmpty { progress("removed \(removed.count) worker simulators left by earlier runs: \(removed.joined(separator: ", "))") }
                progress("creating \(missing) worker simulator\(missing == 1 ? "" : "s") like \(udid)...")
                createdSimulators = try SimulatorWorkers.create(count: missing, like: udid)
                destinations += createdSimulators.map { "id=\($0.udid)" }
                // A new simulator has decided nothing: a permission dialog there stops tests that pass on the first one
                if let problem = SimulatorWorkers.copyPrivacy(from: udid, to: createdSimulators.map(\.udid), bundles: Xcode.hostBundleIdentifiers(xctestrun: xctestrun)) {
                    let message = "The privacy settings of \(udid) for the app under test could not all be given to the worker simulators (\(problem)). A permission dialog there can stop shared processes and fail tests that pass on \(udid); a worker whose tests do not pass without mutants is not used."
                    progress(message)
                    warnings.append(RunWarning(kind: "workerPrivacy", message: message))
                }
            } else {
                // Not a simulator (macOS): the workers share the destination
                destinations += Array(repeating: config.xcode.destination, count: missing)
            }
        }
        // Test processes that run side by side on one machine can fail each other (a fixed port, a lock file, a
        // file with a fixed name in the temporary directory). What is detected in such a run is not final.
        let sharedDestination = Set(destinations).count < destinations.count
        if sharedDestination {
            let message = "\(destinations.count) workers run on one destination (\(config.xcode.destination)), so their test processes can disturb each other. " + (config.confirmKills == .none
                ? "With --confirm-kills none, a test that fails for that reason is reported as a detection."
                : "Every mutant that is detected while they run side by side is run again alone at the end, and that run decides; --workers therefore saves time only on the mutants that survive.")
            progress(message)
            warnings.append(RunWarning(kind: "sharedDestination", message: message))
        }
        try stopIfInterrupted()
        let workers = destinations.enumerated().map { index, destination -> MutantExecutor.Worker in
            var worker = runXcode
            worker.options.destination = destination
            if index > 0 { worker.testDerivedDataName = "TestDerivedData-w\(index)" }
            return MutantExecutor.Worker(index: index, xcode: worker)
        }
        // A destination that shares the CPU with others is slower
        let workerFactor = config.timeoutFactor * (1 + 0.25 * Double(workers.count - 1))
        let workerTimeout = baselineOutcome.duration * workerFactor + config.timeoutConstant
        // A run of narrowed tests gets a timeout from the time those tests took in the baseline
        // For the checks of the fixture only: behave as if no output of the baseline had shown its tests, so that
        // the times from the result bundle (with --select-tests reach) and the warning (without) are exercised
        let blind = ProcessInfo.processInfo.environment[ToolNaming.environmentPrefix + "IGNORE_BASELINE_TEST_LINES"] != nil
        let timeouts = TimeoutPolicy.make(baselineSeconds: baselineOutcome.duration, suiteSeconds: selector?.suiteSeconds,
                                          factor: workerFactor, constant: config.timeoutConstant, startupSeconds: blind ? nil : baselineOutcome.firstMarkerAfter,
                                          // What one test may take: the longest test of the baseline, or the longest time between two lines of
                                          // tests in its log (which also holds what runs between tests), whichever is longer
                                          longestTestSeconds: [(try? String(contentsOf: baselineLog, encoding: .utf8)).flatMap(TimeoutPolicy.longestTest),
                                                               (try? String(contentsOf: baselineTrace, encoding: .utf8)).flatMap(TimeoutPolicy.longestTest),
                                                               baselineOutcome.longestQuiet]
                                              .compactMap { $0 }.max().flatMap { blind ? nil : $0 })
        if let notInUse = timeouts.limitsNotInUse {
            progress("warning: \(notInUse)")
            warnings.append(RunWarning(kind: "limitsNotInUse", message: notInUse))
        } else if let inUse = timeouts.limitsInUse {
            // (Said in every run: when these limits were silently off, only the time of the run showed it)
            progress(inUse)
        }

        // Shared processes: one per unit (test-plan configuration × unit-test target); a selection with a UI test target runs alone
        var sharedSetup: SharedProcess.Setup?
        var sharedUnavailable: String?
        var sharedChosen = config.sharedProcess
        if config.sharedProcessAuto {
            let toRun = active.filter { reached.contains($0.id) }
            // The second run at the start of a shared process: the suites of the mutants (`MutantExecutor.narrowedGate`)
            var secondRun: Double?
            if config.narrowGate, let selector, selector.usable {
                var union: Set<String> = []
                var narrowed = !toRun.isEmpty
                for mutant in toRun {
                    guard let selection = selector.selection(for: mutant.id, evenlyEvaluated: true) else { narrowed = false; break }
                    union.formUnion(selection.onlyTesting)
                }
                if narrowed { secondRun = timeouts.testSeconds(of: union.sorted()) }
            }
            let choice = sharedProcessChoice(units: (try? SharedProcess.units(xctestrun: xctestrun, options: runXcode.options).get().count) ?? 1,
                                             mutants: toRun.count, timeouts: timeouts, baselineSeconds: baselineOutcome.duration, secondRun: secondRun)
            durations.sharedProcessChoice = choice
            sharedChosen = choice.used
            progress("--shared-process auto: \(choice.reason)")
        }
        if sharedChosen {
            switch SharedProcess.units(xctestrun: xctestrun, options: runXcode.options) {
            case let .failure(reason):
                sharedUnavailable = reason.description
            case let .success(targets):
                do {
                    let units = try targets.map { target in
                        SharedProcess.Unit(target: target, driver: try SharedProcess.buildDriver(for: target, in: sessionsDirectory,
                                                                                                 log: logsDirectory.appendingPathComponent("shared-process-driver.log")))
                    }
                    let developer = (try? Subprocess.capture(["/usr/bin/xcode-select", "-p"], timeout: 60))
                        .flatMap { $0.status == 0 ? $0.output.trimmingCharacters(in: .whitespacesAndNewlines) : nil } ?? ""
                    sharedSetup = SharedProcess.Setup(units: units, originalXctestrun: xctestrun, switchCount: nextID,
                                                      expectedTests: evidence.testCount, launchTimeout: max(workerTimeout, 180),
                                                      timeoutFactor: config.timeoutFactor, timeoutConstant: config.timeoutConstant,
                                                      placeholders: .init(developerDirectory: developer, productsDirectory: xctestrun.deletingLastPathComponent().path,
                                                                          derivedData: derivedData.path),
                                                      directLaunch: config.directLaunch && !developer.isEmpty, names: names,
                                                      confirmation: config.confirmKills)
                    if units.count > 1 {
                        progress("shared processes: \(units.count) units per round (\(units.map(\.target.label).joined(separator: ", ")))")
                    }
                } catch let reason as SharedProcess.Unavailable {
                    sharedUnavailable = reason.description
                }
            }
            if let sharedUnavailable {
                progress("--shared-process cannot be used (\(sharedUnavailable)); running every mutant in a process of its own")
                warnings.append(RunWarning(kind: "sharedProcessUnavailable", message: "--shared-process was not used: \(sharedUnavailable). Every mutant was run in a process of its own."))
            }
        }

        let executor = MutantExecutor(
            inputs: .init(session: self, config: config, journal: journal, xctestrun: xctestrun, xcode: runXcode, evidence: evidence,
                          selector: selector, timeout: workerTimeout, timeouts: timeouts, baselineTimeout: config.baselineTimeout, shared: sharedSetup, switchCount: nextID,
                          confirmation: config.confirmKills, restore: restore, sharedDestination: sharedDestination,
                          recheckSurvivors: config.recheckSurvivors && selector != nil),
            workers: workers)
        let mutantPhaseStart = Date()
        RunProgress.begin("mutants", hint: { executor.progressHint() })
        var executorError: Error?
        do {
            try executor.run(active: active, reached: reached)
        } catch {
            executorError = error
        }
        for (id, result) in executor.results { results[id] = result }
        pending += executor.pending
        // Every mutant that was to be run has a result, or is listed as not run. Anything else is a defect of the tool
        // and must show: a mutant that silently drops out of the report looks like a mutant that does not exist
        if executorError == nil {
            let pendingKeys = Set(pending)
            for mutant in active where results[mutant.id] == nil && !pendingKeys.contains(mutant.key) {
                record(mutant, .runnerError, detail: "no result was recorded for this mutant (a defect of \(ToolInfo.name); please report it)")
            }
        }
        resumedCount = executor.resumedCount
        warnings += executor.warnings
        let warningsTaken = executor.warnings.count
        durations.mutantSeconds = executor.mutantSeconds
        durations.executedMutants = executor.executedCount
        durations.mutantPhaseSeconds = Date().timeIntervalSince(mutantPhaseStart)
        durations.workers = executor.liveWorkers.count
        if sharedSetup != nil {
            durations.sharedProcess = .init(processes: executor.sharedProcesses, seconds: executor.sharedSeconds, killed: executor.sharedKilled,
                                            passed: executor.sharedSurvived, alone: executor.aloneCount, trustedSurvivors: config.trustSharedSurvivors,
                                            units: sharedSetup?.units.count, directProcesses: executor.directSessions,
                                            confirmedDirectly: executor.confirmedDirectly, pausedAlone: executor.pausedCount,
                                            withoutStartupRuns: executor.ungatedSessions, narrowedStartupRuns: executor.narrowedGates,
                                            timedOut: executor.sharedTimeouts)
            progress(String(format: "shared processes: %d (%.0fs in total, %d started without xcodebuild, %d without the two runs at the start), %d mutants killed there, %d timed out there, %d passed there%@, %d runs under xcodebuild%@",
                            executor.sharedProcesses, executor.sharedSeconds, executor.directSessions, executor.ungatedSessions, executor.sharedKilled, executor.sharedTimeouts, executor.sharedSurvived,
                            config.trustSharedSurvivors ? " (not run again)" : " (\(executor.confirmedDirectly) confirmed in a new process started by the tool)",
                            executor.aloneCount, executor.pausedCount > 0 ? " (\(executor.pausedCount) of them while shared processes were paused)" : ""))
        }
        if let executorError { throw executorError }
        let narrowedCount = executor.narrowedCount
        let unnarrowedCount = executor.unnarrowedCount
        interrupted = InterruptState.isInterrupted
        if selector != nil {
            if testSelection?.mode != "impact" { testSelection?.mode = "reach" }
            testSelection?.narrowedMutants = narrowedCount
            testSelection?.unnarrowedMutants = unnarrowedCount
            progress("tests selected by reach for \(narrowedCount) mutants; \(unnarrowedCount) were run against the whole selection")
            testSelection?.recheckSurvivors = config.recheckSurvivors
            let narrowedOnly = executor.results.values.filter { $0.narrowedOnly == true && $0.status == .survived }.count
            testSelection?.detectedNarrowedOnly = executor.results.values.filter { $0.narrowedOnly == true && $0.status.isDetected }.count
            testSelection?.detectedNarrowedOnlyShared = executor.results.values.filter { $0.narrowedOnly == true && $0.status.isDetected && $0.sharedProcess == true }.count
            testSelection?.survivedNarrowedOnly = narrowedOnly
            if narrowedOnly > 0 {
                let message = "\(narrowedOnly) mutants are reported as Survived after passing only the tests that reach them; they were not run against the other tests (--no-recheck-survivors). A test that reads state left by a test that runs the mutated code (a singleton that one suite configures and another reads) could still detect them. They are marked `narrowedOnly` in the reports; run without --no-recheck-survivors to have them run against every test."
                progress(message)
                warnings.append(RunWarning(kind: "survivorsNotRechecked", message: message))
            }
        }
        if resumedCount > 0 { progress("\(resumedCount) results taken from the journal of the earlier run") }
        if executor.recheckedSurvivors > 0 {
            progress("recheck of survivors: \(executor.recheckedSurvivors) mutants that survived the tests that reach them were run against the whole selection; detected there: \(executor.recheckedDetected)")
        }

        if !interrupted { try? journal.recordFinished() }
        if interrupted {
            warnings.append(cutShort(": \(pending.count) mutants were not run. The results so far are in this report; continue with --resume (same options, unchanged sources)."))
        } else {
            // Run the baseline once more at the end. If it fails, either app data (UserDefaults, DB, etc.) was carried over
            // between mutant runs or there are flaky tests, and the results cannot be trusted
            // Where the last run did not pass, the tests have just been run without mutants (and a failure there is
            // reported with the mutant that caused it): that run is the final baseline of the destination
            let settledWorkers = executor.settleDestinations()
            if InterruptState.isInterrupted {
                interrupted = true
                warnings.append(cutShort(" after the last mutant; all mutants were run, but the check for state left by earlier runs was not completed."))
            }
            warnings += executor.warnings.dropFirst(warningsTaken)
            let unsettledWorkers = executor.liveWorkers.sorted().filter { !settledWorkers.contains($0) }
            if !unsettledWorkers.isEmpty, !interrupted {
                RunProgress.begin("final baseline", hint: {
                    RunProgress.endedTests(inLog: self.logsDirectory.appendingPathComponent("baseline-final.log").path).map { "\($0) tests ended so far" }
                })
                progress("final baseline (all mutants off)\(unsettledWorkers.count > 1 ? " on each of \(unsettledWorkers.count) workers" : "")...")
            }
            for index in executor.liveWorkers.sorted() where !settledWorkers.contains(index) && !interrupted {
                let suffix = index == 0 ? "" : "-w\(index)"
                let finalLog = logsDirectory.appendingPathComponent("baseline-final\(suffix).log")
                let finalBundle = resultsDirectory.appendingPathComponent("baseline-final\(suffix).xcresult")
                let finalOutcome = try workers[index].xcode.testWithoutBuilding(xctestrun: xctestrun, environment: [:], resultBundle: finalBundle,
                                                                                log: finalLog, timeout: config.baselineTimeout)
                durations.finalBaselineSeconds += finalOutcome.duration
                let finalSummary = TestSummary.load(finalBundle)
                let place = index == 0 ? "" : " on worker \(index + 1) (\(workers[index].xcode.options.destination))"
                if InterruptState.isInterrupted {
                    interrupted = true
                    warnings.append(cutShort(" during the final baseline; all mutants were run, but the check for state left by earlier runs was not completed."))
                    break
                } else if finalOutcome.status != 0 || finalOutcome.timedOut || (finalSummary?.failedTests ?? 1) > 0 {
                    let failures = finalSummary?.failures.prefix(3).map(\.test).joined(separator: ", ") ?? "unknown"
                    warnings.append(RunWarning(kind: "stateLeak", message: "The baseline failed when run again after all mutants\(place) (\(failures)). State left by earlier runs (UserDefaults, files, databases) or flaky tests may have affected the results. Log: \(finalLog.path)"))
                } else if let finalSummary, finalSummary.totalTestCount != evidence.testCount {
                    warnings.append(RunWarning(kind: "stateLeak", message: "The baseline ran \(finalSummary.totalTestCount) tests when run again after all mutants\(place); the first baseline ran \(evidence.testCount). The set of tests is not stable, so the results may not be comparable. Log: \(finalLog.path)"))
                }
            }
        }

        durations.confirmation = .init(mode: config.confirmKills.rawValue, controlRuns: executor.controlRuns, controlSeconds: executor.controlSeconds,
                                       repeatedRuns: executor.confirmationRuns, notConfirmed: executor.unconfirmedKills,
                                       runAgainAlone: executor.serialConfirmations,
                                       recheckedSurvivors: config.recheckSurvivors ? executor.recheckedSurvivors : nil,
                                       recheckedDetected: config.recheckSurvivors ? executor.recheckedDetected : nil,
                                       detectionsRunAgainstAll: config.confirmKills == .full ? executor.detectionsRunAgainstAll : nil,
                                       detectionsNotConfirmedByAll: config.confirmKills == .full ? executor.detectionsNotConfirmedByAll : nil,
                                       restoredStates: restore != nil ? executor.restoredStates : nil,
                                       restoreFallbacks: restore != nil ? executor.restoreFallbacks.values.reduce(0, +) : nil)
        if restore != nil {
            let fallbacks = executor.restoreFallbacks.values.reduce(0, +)
            progress("--confirm-kills restore: \(executor.restoredStates) runs without mutants replaced by putting the snapshot back; \(fallbacks) run as with auto because it could not be done")
            if fallbacks > 0 {
                let reasons = executor.restoreFallbacks.sorted { $0.value > $1.value }.prefix(5).map { "\($0.value)× \($0.key)" }.joined(separator: "; ")
                warnings.append(RunWarning(kind: "restoreFellBack", message: "--confirm-kills restore: \(fallbacks) times the snapshot could not stand for a run without mutants, and the tests were run instead: \(reasons)"))
            }
        }
        if config.confirmKills == .full, executor.detectionsRunAgainstAll > 0 {
            progress("--confirm-kills full: \(executor.detectionsRunAgainstAll) mutants that their narrowed tests detected were run against the whole selection; passed there (Survived): \(executor.detectionsNotConfirmedByAll)")
        }
        if executor.controlRuns + executor.confirmationRuns + executor.serialConfirmations > 0 {
            progress(String(format: "confirmation of detections (--confirm-kills %@): %d runs without mutants between mutants (%.0fs), %d mutants run a second time (%d passed then), %d detections seen in parallel run again alone",
                            config.confirmKills.rawValue, executor.controlRuns, executor.controlSeconds, executor.confirmationRuns, executor.unconfirmedKills, executor.serialConfirmations))
            // Not after --shared-process auto has weighed it, and not for a handful of runs
            if durations.sharedProcessChoice == nil, executor.controlRuns >= 5,
               let hint = Self.controlShareHint(controlSeconds: executor.controlSeconds, mutantPhaseSeconds: durations.mutantPhaseSeconds ?? 0, sharedProcess: sharedSetup != nil) {
                progress(hint)
            }
        }

        // Where the time went: the parts that are as long as runs of the tests, and the rest
        if let phase = durations.mutantPhaseSeconds, executor.executedCount > 0 {
            let b = executor.breakdown
            // The parts are summed over the workers; `fitted` makes those of the time they ran side by side shares of it
            let breakdown = RunDurations.Breakdown.fitted(RunDurations.Breakdown(
                startupRunSeconds: b.startupRunSeconds, startupRunProcesses: b.startupRunProcesses,
                wholeSelectionSeconds: b.wholeSelectionSeconds, wholeSelectionMutants: b.wholeSelectionMutants, wholeSelectionReasons: b.wholeSelectionReasons,
                wholeSelectionStopped: b.wholeSelectionStopped,
                ownTestsSeconds: b.ownTestsSeconds, ownTestsMutants: b.ownTestsMutants, recheckSeconds: b.recheckSeconds, recheckMutants: b.recheckMutants,
                controlSeconds: executor.controlSeconds, finalBaselineSeconds: durations.finalBaselineSeconds, lostProcesses: b.lostProcesses,
                otherSeconds: 0, totalSeconds: 0), phaseSeconds: phase, parallel: executor.parallelSpan.map { span in
                    (RunDurations.Breakdown(startupRunSeconds: span.breakdown.startupRunSeconds, startupRunProcesses: 0, wholeSelectionSeconds: span.breakdown.wholeSelectionSeconds,
                                            wholeSelectionMutants: 0, wholeSelectionReasons: [:], ownTestsSeconds: span.breakdown.ownTestsSeconds, ownTestsMutants: 0,
                                            recheckSeconds: span.breakdown.recheckSeconds, recheckMutants: 0, controlSeconds: span.controlSeconds, finalBaselineSeconds: 0,
                                            lostProcesses: 0, otherSeconds: 0, totalSeconds: 0),
                     span.seconds, span.workerSeconds, executor.workerCount)
                })
            durations.breakdown = breakdown
            progress(breakdown.line)
        }

        // Keep what this run killed for later runs (--reuse). A run whose final baseline failed, or did not take place
        // because the run was interrupted, is not a source of results
        if config.reuse, let state = reuseState, !interrupted, !warnings.contains(where: { $0.kind == "stateLeak" }) {
            let store = Reuse.updated(reuseStore, environment: reuseEnvironment, state: state, results: selected.compactMap { results[$0.id] },
                                      declarations: reuseDeclarations, commit: commit.flatMap { $0.dirty ? nil : $0.sha })
            do {
                try store.save(to: reuseStoreURL)
                reuseSummary?.storedCount = store.entries.count
            } catch {
                warnings.append(RunWarning(kind: "reuseStore", message: "The results for --reuse could not be written to \(reuseStoreURL.path): \(error)"))
            }
        }

        // Accepted: Accepted if not detected, a warning if detected. Those that no longer exist also produce a warning
        let acceptedKeys = config.accepted.keys
        if !acceptedKeys.isEmpty {
            var killed: [String] = []
            for (id, result) in results where acceptedKeys.contains(result.mutant.key) {
                if result.status.isUndetected {
                    results[id]?.status = .accepted
                } else if result.status.isDetected {
                    killed.append(result.mutant.key)
                    warnings.append(RunWarning(kind: "acceptedButKilled", message: "accepted mutant is detected now; remove it from \(AcceptedFile.defaultName)", key: result.mutant.key))
                }
            }
            let scannedFiles = Set(config.files)
            let stale = acceptedKeys.filter { key in
                let parts = key.components(separatedBy: "::")
                let file = parts.first ?? ""
                // An entry for an operator that is switched off now is not stale: it applies again when the operator is back
                if parts.count >= 4, let op = MutationOperator(rawValue: parts[2]), !config.generatorOptions.operators.contains(op) { return false }
                // A file that no longer exists (deleted, renamed or moved) has no mutant under its old path, whatever was scanned
                if !fm.fileExists(atPath: config.root.appendingPathComponent(file).path) { return true }
                return scannedFiles.contains(file) && skipped[file] == nil && !allKeys.contains(key)
            }.sorted()
            for key in stale {
                warnings.append(RunWarning(kind: "staleAccepted", message: "accepted mutant no longer exists; remove it from \(AcceptedFile.defaultName)", key: key))
            }
            acceptance = RunReport.Acceptance(killed: killed.sorted(), stale: stale)
        }

        let report = makeReport(baseline: baseline)
        let notActivated = report.results.filter { $0.status == .notActivated }.count
        if notActivated > 0 {
            warnings.append(RunWarning(kind: "notActivated", message: "\(notActivated) mutants passed without an activation record; they are not counted as survived"))
        }
        return makeReport(baseline: baseline)
    }

    /// The configuration of this run and the list of mutants that go into the record fingerprint.
    func fingerprintParts(_ selected: [Mutant]) -> [String] {
        let x = config.xcode
        var parts = config.fingerprintParts
        parts.append("root=\(config.root.path)")
        parts.append("xcode=\(x.container)|\(x.scheme ?? "")|\(x.destination)|\(x.testPlan ?? "")|\(x.extraBuildArguments)|\(x.extraTestArguments)|\(x.onlyTesting)|\(x.skipTesting)|\(x.buildSettings)|\(x.workingDirectory ?? "")")
        parts.append("prepare=\(config.prepareCommand ?? "")")
        parts.append("timeout=\(config.timeoutFactor)x+\(config.timeoutConstant)")
        parts.append("selectTests=\(config.selectTestsAutomatically)|reach=\(config.selectTestsByReach)|impact=\(config.impactMap?.path ?? "")")
        parts.append("confirmKills=\(config.confirmKills.rawValue)")
        // What an observation in the journal holds and when it is written (2: only settled runs, with the suites
        // they were narrowed to). A journal of another form is not continued
        parts.append("journal=\(Journal.formatVersion)")
        if config.selectTestsByReach { parts.append("recheckSurvivors=\(config.recheckSurvivors)") }
        // How mutants are run decides what an observation in the journal means (a pass in a shared process is a verdict
        // only with --trust-shared-survivors; timeouts and confirmations depend on the workers)
        parts.append("sharedProcess=\(config.sharedProcessAuto ? "auto" : String(config.sharedProcess))|trust=\(config.trustSharedSurvivors)|directLaunch=\(config.directLaunch)|narrowGate=\(config.narrowGate)|stopAtFirstFailure=\(config.stopAtFirstFailure)")
        parts.append("workers=\(config.workers)|\(config.additionalDestinations)")
        parts.append("copyRoot=\(config.copyRoot?.path ?? "")")
        if config.reuse { parts.append("reuse") }
        parts.append("mutants=" + selected.map { "\($0.id):\($0.key)" }.joined(separator: ","))
        return parts
    }

    /// Why a file was skipped, for a reader who does not know the reason codes of `MutantGenerator`.
    static func skipExplanation(_ reason: String) -> String {
        switch reason {
        case "parse-error":
            "the tool's parser reports a syntax error in it (\(reason)). If the compiler accepts the file, it uses syntax that the swift-syntax version of this tool does not know, or has text in an `#if` branch that is never compiled; no mutant of this file was made or run"
        case "fold-changed-text":
            "folding its operators did not reproduce the text (\(reason)); no mutant of this file was made or run"
        default:
            "\(reason); no mutant of this file was made or run"
        }
    }

    /// The HEAD of the target repository and whether there are uncommitted changes.
    static func commit(of root: URL) -> RunReport.Commit? {
        guard let head = try? Subprocess.capture(["git", "-C", root.path, "rev-parse", "HEAD"], timeout: 60), head.status == 0,
              let status = try? Subprocess.capture(["git", "-C", root.path, "status", "--porcelain"], timeout: 120), status.status == 0 else { return nil }
        return RunReport.Commit(sha: head.output.trimmingCharacters(in: .whitespacesAndNewlines),
                                dirty: !status.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    /// `--select-tests impact`: the suites for the files changed since the map's commit, or why all tests run.
    func impactSelection(map url: URL, xctestrun: URL) -> (suites: [String]?, commit: String, changedFiles: [String], newSuites: [String], reasons: [String]) {
        guard let data = try? Data(contentsOf: url), let map = try? JSONDecoder().decode(ImpactMap.self, from: data) else {
            return (nil, "", [], [], ["the impact map \(url.path) could not be read"])
        }
        guard map.version == ImpactMap.formatVersion else { return (nil, map.commit, [], [], ["the impact map has format version \(map.version), this tool reads \(ImpactMap.formatVersion)"]) }
        let root = config.root.path
        guard let ancestor = try? Subprocess.capture(["git", "-C", root, "merge-base", "--is-ancestor", map.commit, "HEAD"], timeout: 60), ancestor.status == 0 else {
            return (nil, map.commit, [], [], ["the map's commit \(map.commit.prefix(10)) is not an ancestor of HEAD in this clone (fetch the history, or make a new map)"])
        }
        var changed: Set<String> = []
        for arguments in [["diff", "--name-only", "--no-renames", map.commit, "HEAD"], ["diff", "--name-only", "--no-renames", "HEAD"], ["ls-files", "--others", "--exclude-standard"]] {
            guard let out = try? Subprocess.capture(["git", "-C", root, "-c", "core.quotepath=false"] + arguments, timeout: 120), out.status == 0 else {
                return (nil, map.commit, [], [], ["git could not list the files changed since \(map.commit.prefix(10))"])
            }
            changed.formUnion(out.output.split(whereSeparator: \.isNewline).map(String.init))
        }
        let targets = TestSelector.testTargets(xctestrun: xctestrun).filter { !$0.isUITest }.map(\.name)
        let files = changed.sorted()
        switch map.selection(changed: files, source: { try? String(contentsOf: self.config.root.appendingPathComponent($0), encoding: .utf8) }, testTargets: targets) {
        case let .suites(suites, newSuites):
            if suites.isEmpty { return (nil, map.commit, files, [], ["none of the changed files is in the map or declares tests"]) }
            return (suites, map.commit, files, newSuites, [])
        case let .all(reasons):
            return (nil, map.commit, files, [], reasons)
        }
    }

    /// `--confirm-kills restore`: the snapshot, or why it cannot be used. It needs one iOS simulator named by id,
    /// one app-hosted test target (the containers are those of the host app), and one worker.
    func prepareRestore(xctestrun: URL, xcode: Xcode) -> Result<SimulatorRestore, SimulatorRestore.Failure> {
        guard config.workers <= 1, config.additionalDestinations.isEmpty else { return .failure(.init("it is used with one worker only")) }
        guard let udid = xcode.simulatorUDID else { return .failure(.init("the destination is not an iOS simulator named by id; on macOS there are no app containers to put back")) }
        guard case let .success(units) = SharedProcess.units(xctestrun: xctestrun, options: xcode.options), !units.isEmpty else {
            return .failure(.init("the test targets of the .xctestrun file could not be read"))
        }
        let hosts = Set(units.compactMap { $0.isAppHosted ? $0.hostBundleIdentifier : nil })
        guard units.allSatisfy(\.isAppHosted), hosts.count == 1, let bundle = hosts.first, let app = units.first?.hostPath, !app.isEmpty else {
            return .failure(.init("it needs app-hosted unit tests with one host app; tests without a host app keep their state in places that are not put back"))
        }
        let install = try? Subprocess.capture(["/usr/bin/xcrun", "simctl", "install", udid, app], timeout: 600)
        guard install?.status == 0 else { return .failure(.init("the host app could not be installed on the simulator before the baseline")) }
        let made = SimulatorRestore(udid: udid, bundleIdentifier: bundle, directory: config.workDirectory.appendingPathComponent("restore/snapshot"))
        do {
            try made.take()
        } catch let failure as SimulatorRestore.Failure {
            return .failure(failure)
        } catch {
            return .failure(.init("\(error)"))
        }
        return .success(made)
    }

    /// The choice of `--shared-process auto`. A run that is continued (`--resume`) keeps the choice of the run it
    /// continues, which is kept in the work directory: the observations in the journal were made in that mode.
    func sharedProcessChoice(units: Int, mutants: Int, timeouts: TimeoutPolicy, baselineSeconds: Double, secondRun: Double?) -> RunDurations.SharedProcessChoice {
        let file = config.workDirectory.appendingPathComponent("shared-process-choice.json")
        if config.resume, let data = try? Data(contentsOf: file),
           var earlier = try? JSONDecoder().decode(RunDurations.SharedProcessChoice.self, from: data) {
            earlier.reason += " (the choice of the run that is continued)"
            return earlier
        }
        // A launch: what the baseline needed until its first test started, or else what it spent outside its tests
        let launch = timeouts.startupSeconds ?? (timeouts.suiteSeconds.isEmpty ? nil : timeouts.overheadSeconds)
        // One run without mutants at the start: the tests of the whole selection
        let tests = timeouts.suiteSeconds.isEmpty ? max(baselineSeconds - (launch ?? 0), 0) : timeouts.suiteSeconds.values.reduce(0, +)
        let choice = SharedProcessChoice.decide(mutants: mutants, launchSeconds: launch, startupRunSeconds: tests,
                                                secondRunSeconds: units == 1 ? secondRun : nil, units: units)
        if let data = try? JSONEncoder().encode(choice) { try? data.write(to: file) }
        return choice
    }

    /// With one process per mutant, each detection is followed by a launch of the test host without mutants. When
    /// those launches are a large part of the mutant phase, the line says so and names what makes them cheaper.
    static func controlShareHint(controlSeconds: Double, mutantPhaseSeconds: Double, sharedProcess: Bool) -> String? {
        guard !sharedProcess, mutantPhaseSeconds > 0, controlSeconds / mutantPhaseSeconds >= 0.3 else { return nil }
        return String(format: "the runs without mutants took %.0f%% of the mutant phase: with one process per mutant, every run that does not pass is followed by one, so that state it left on the destination is not taken for a detection of the next mutant. With --shared-process these runs are made inside the test process (docs/speed.md).", controlSeconds / mutantPhaseSeconds * 100)
    }

    static func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total >= 3600 { return "\(total / 3600)h\(String(format: "%02d", (total % 3600) / 60))m" }
        if total >= 60 { return "\(total / 60)m\(String(format: "%02d", total % 60))s" }
        return "\(total)s"
    }

    /// The message for a build that failed without a compiler error: what `xcodebuild` itself said, and, where the
    /// cause is a known one, what to do about it. (A guess such as "a script phase, linking or signing?" in place of
    /// the error line that is in the log sends the reader the wrong way.)
    static func buildFailureWithoutCompilerErrors(log: String) -> String {
        let lines = log.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        var errors: [String] = []
        for line in lines where line.hasPrefix("xcodebuild: error:") || line.hasPrefix("error:") || line.contains(": error: ") {
            if !errors.contains(line) { errors.append(line) }
        }
        let shown = errors.suffix(5).map { "\n    " + String($0.prefix(400)) }.joined()
        var hint = ""
        let all = errors.joined(separator: "\n")
        if all.contains("missing DEVELOPER_DIR") || all.contains("requires Xcode") || all.contains("unable to find utility \"xcodebuild\"") || all.contains("no developer tools were found") {
            hint = "\n  Xcode was not found. \(ToolInfo.name) runs xcodebuild, so it needs the Xcode application (the Command Line Tools alone are not enough), selected with `sudo xcode-select -s /Applications/Xcode.app` or named in DEVELOPER_DIR. `xcode-select -p` shows what is selected."
        } else if all.contains("does not contain a scheme named") || all.contains("Scheme") && all.contains("is not currently configured") {
            hint = "\n  Check --scheme. `xcodebuild -list` (in the package directory, or with -project / -workspace) shows the schemes; for a Swift package the scheme is the name of its one product, or <name>-Package when the package declares no product or several."
        } else if all.contains("Could not resolve package dependencies") || all.contains("Authentication failed") || all.contains("could not read Username") {
            hint = "\n  The Swift packages could not be fetched in the work copy. --package-cache <an existing SourcePackages directory> avoids fetching them again."
        } else if all.contains("requires a development team") || all.contains("No profiles for") || all.contains("Signing for") || all.contains("Code Signing Error") {
            hint = "\n  Code signing failed. For simulator and macOS test runs, --build-arg=CODE_SIGNING_ALLOWED=NO usually avoids it."
        } else if all.contains("Unable to find a destination matching") || all.contains("Unable to find a device matching") {
            hint = "\n  Check --destination (for a simulator: 'id=<UDID>' from `xcrun simctl list devices`)."
        }
        if errors.isEmpty {
            return "build-for-testing failed and the log names no error (a script phase, linking or signing may have failed); see the end of the log"
        }
        return "build-for-testing failed (no compiler error; nothing points to a mutant):\(shown)\(hint)"
    }

    /// If the build log has "file not found" errors, returns guidance about the files missing from the work copy.
    func missingFileHint(inLog log: String) -> String {
        let markers = ["No such file or directory", "could not find included file", "unable to open", "does not exist",
                       "doesn’t exist", "doesn't exist", "couldn’t be opened", "couldn't be opened", "cannot be found", "not found"]
        let lines = log.split(separator: "\n").filter { line in
            line.contains("error") && markers.contains { line.contains($0) }
        }
        guard let first = lines.first else { return "" }
        return """

              A file was not found: \(first.trimmingCharacters(in: .whitespaces).prefix(300))
              The build runs in a copy of \(layout.copyRoot.path) that holds only git-tracked files and untracked files that are not ignored.
              Files ignored by git (generated sources, local xcconfig / plist files, Pods) and files outside that directory are not in the copy.
              Create them with --prepare, which runs in the copy of --root with \(RunSession.originalRootEnvironmentVariable) set to the original directory, e.g.
                --prepare 'cp "$\(RunSession.originalRootEnvironmentVariable)/Config/Local.xcconfig" Config/ && xcodegen generate'
            """
    }

    /// Rewrites the target files in the work copy with text in which only the specified mutants are instrumented.
    func instrument(_ mutants: [Mutant], sources: [String: String]) throws {
        let byFile = Dictionary(grouping: mutants, by: \.file)
        branchMaps = [:]
        for (file, source) in sources {
            let fileMutants = byFile[file] ?? []
            let (instrumented, branches) = Instrumenter.instrumentWithBranches(source: source, mutants: fileMutants, names: names)
            branchMaps[file] = (instrumented, branches)
            let verification = InstrumentationVerifier.verify(original: source, instrumented: instrumented, mutants: fileMutants)
            guard verification.isValid else {
                throw RunError.stage("instrument", "static verification failed for \(file): \(verification.problems.joined(separator: "; "))", log: nil)
            }
            // Atomic: the file in the copy may be a link, and its target (the user's own file) must not be written to
            try SourceText.write(instrumented, to: sourceDirectory.appendingPathComponent(file))
        }
    }

    /// Identifies the offending mutants from the positions of build errors.
    /// Instrumentation keeps line numbers identical to the original source, so mutants whose range contains the error line are removed.
    /// Identification widens from the narrowest scope (to reduce bisection builds):
    /// 1. A mutated branch containing the diagnostic position (line and column) → only that mutant
    /// 2. Expression/statement switches on the diagnostic's line → all mutants on that line
    /// 3. All mutants in the declaration (function, etc.) containing the diagnostic's line (e.g. when a mutation changes a variable's type and a later line fails)
    /// 4. An error in a target file that matches none of these → the mutants of that file become suspects (`suspects`) and the caller bisects
    ///
    /// 2 and 3 may remove innocent mutants as collateral, so the reason (detail) says so. A whole file is never removed at once
    /// (with dozens to hundreds of mutants per file, removing too many would thin out the results).
    func analyzeCompileErrors(in log: String, mutants: [Mutant]) -> (culprits: [(Mutant, String)], suspects: [Mutant]) {
        let root = sourceDirectory.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        let byFile = Dictionary(grouping: mutants, by: \.file)
        var culprits: [Int: (Mutant, String)] = [:]
        var suspects: [Int: Mutant] = [:]
        for diagnostic in CompilerDiagnostic.errors(inLog: log) {
            let path = URL(fileURLWithPath: diagnostic.path).standardizedFileURL.resolvingSymlinksInPath().path
            guard path.hasPrefix(root) else { continue }
            let relative = String(path.dropFirst(root.count))
            guard let fileMutants = byFile[relative] else { continue }
            let description = "\(relative):\(diagnostic.line):\(diagnostic.column): \(diagnostic.message)"
            // A switch that empties a body wraps the whole function, so it is not narrowed by line (handled by "same declaration" in 3).
            // Suspect switches that rewrite an expression before switches that merely wrap a statement in `if`
            let covering = fileMutants.filter { $0.operator != .emptyBody && $0.regionLines.contains(diagnostic.line) }
            let rewriting = covering.filter { !$0.operator.removesStatement }
            let onLine = rewriting.isEmpty ? covering : rewriting
            if onLine.isEmpty {
                let inDeclaration = fileMutants.filter { $0.scope.lines.contains(diagnostic.line) }
                if inDeclaration.isEmpty {
                    for m in fileMutants { suspects[m.id] = m }
                } else {
                    for m in inDeclaration where culprits[m.id] == nil {
                        culprits[m.id] = (m, "\(MutantResult.collateralDetailPrefix)\(m.scope.id) (the error is in this declaration, not on a mutated line): \(description)")
                    }
                }
                continue
            }
            // If there is a mutated branch containing the diagnostic position (line and column), remove only that mutant.
            // If none is found (e.g. an error in the original-side branch), remove all mutants on that line (the safe side)
            var pinpointed: [Mutant] = []
            if let map = branchMaps[relative], let offset = Self.byteOffset(in: map.text, line: diagnostic.line, column: diagnostic.column) {
                pinpointed = onLine.filter { m in
                    guard let branch = map.branches[m.id] else { return false }
                    return branch.start <= offset && offset <= branch.end
                }
                // Nested branches (an outer mutated version contains no inner ones, but just in case): narrow to the one with the shortest range
                if let shortest = pinpointed.min(by: { (map.branches[$0.id]?.length ?? 0) < (map.branches[$1.id]?.length ?? 0) }) {
                    pinpointed = [shortest]
                }
            }
            for m in (pinpointed.isEmpty ? onLine : pinpointed) where culprits[m.id] == nil {
                culprits[m.id] = (m, description)
            }
        }
        return (culprits.values.sorted { $0.0.id < $1.0.id }, suspects.values.sorted { $0.id < $1.id })
    }

    /// The byte offset of a (1-based) line/column (UTF-8 bytes) position in the text.
    static func byteOffset(in text: String, line: Int, column: Int) -> Int? {
        var currentLine = 1
        var offset = 0
        for byte in text.utf8 {
            if currentLine == line { break }
            if byte == UInt8(ascii: "\n") { currentLine += 1 }
            offset += 1
        }
        guard currentLine == line else { return nil }
        return offset + column - 1
    }

    struct Evaluation {
        var status: MutantStatus
        var killedBy: [String] = []
        var duration: Double
        var activated: Bool
        var detail: String?
        var log: String?
    }

    /// Runs one mutant and returns the observation (the facts before the verdict).
    /// The limit that a run is reported to have exceeded: that of the whole run, or, when one of the limits around
    /// the first test stopped it, the time after which that happened.
    static func exceededLimit(_ outcome: ProcessOutcome, timeout: Double) -> Double {
        outcome.watchLimit == nil ? timeout : outcome.duration.rounded(.down)
    }

    func execute(_ mutant: Mutant, xcode: Xcode, xctestrun: URL, timeout: Double, attempt: Int, watch: LogWatch? = nil) throws -> (MutantObservation, log: String) {
        // Every run of a mutant under xcodebuild keeps a log of its own: the first is `mutant-<id>.log`, the
        // following ones `mutant-<id>-run2.log`, `-run3.log`, … (a run that is repeated after a limit stopped it,
        // the second run of a Crash, a run after a shared process); none overwrites another
        runCountLock.lock()
        runCounts[mutant.id, default: 0] += 1
        let number = runCounts[mutant.id] ?? 1
        runCountLock.unlock()
        let suffix = number > 1 ? "-run\(number)" : ""
        let trace = tracesDirectory.appendingPathComponent("\(mutant.id)\(suffix).trace")
        let log = logsDirectory.appendingPathComponent("mutant-\(mutant.id)\(suffix).log")
        let bundle = resultsDirectory.appendingPathComponent("mutant-\(mutant.id)\(suffix).xcresult")
        try? FileManager.default.removeItem(at: trace)
        let started = Date()
        let outcome = try xcode.testWithoutBuilding(
            xctestrun: xctestrun,
            environment: [
                "TEST_RUNNER_\(names.active)": String(mutant.id),
                "TEST_RUNNER_\(names.trace)": trace.path,
            ],
            resultBundle: bundle, log: log, timeout: timeout, watch: watch)
        let activated = Trace.read(trace).activated.contains(mutant.id)
        defer {
            if !config.keepResultBundles { try? FileManager.default.removeItem(at: bundle) }
        }

        if outcome.timedOut {
            xcode.terminateHostApps(xctestrun: xctestrun, logDirectory: logsDirectory)
        }
        let logText = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        let summary = outcome.timedOut ? nil : TestSummary.load(bundle)
        var observation = MutantObservation(
            key: mutant.key, id: mutant.id, attempt: attempt, exitStatus: outcome.status, timedOut: outcome.timedOut,
            summary: summary, activated: activated, runnerErrorPattern: RunnerErrorPatterns.match(in: logText),
            // What the report says the run exceeded: the limit that stopped it
            durationSeconds: outcome.duration, timeoutSeconds: Self.exceededLimit(outcome, timeout: timeout))
        let running = outcome.runningAtStop.isEmpty ? "" : "; running then: " + outcome.runningAtStop.prefix(5).joined(separator: ", ")
        func seconds(_ value: Double?) -> String { value.map { String(format: "%.0f s", $0) } ?? "the limit" }
        switch outcome.watchLimit {
        case "startup":
            observation.stoppedBeforeTests = true
            observation.limitNote = "no test had started after \(seconds(watch?.startupLimit)) (the limit until the first test: --timeout-factor × the time the baseline needed to get there + --timeout-constant; the run was made twice)"
        case "stall":
            observation.stoppedInTest = true
            observation.limitNote = "one test did not end: no test or suite started or ended for \(seconds(watch?.stallLimit)) (the limit for one test: --timeout-factor × the longest such time of the baseline + --timeout-constant; the run was made twice\(running))"
        case "afterStart":
            observation.limitNote = "the run went on for more than \(seconds(watch?.afterStart)) after its first test had started (the limit of the run, \(String(format: "%.0f s", timeout)), less what it allows for starting the host)"
        case "crash":
            observation.crashedIn = outcome.crashedIn ?? ""
            observation.failedBeforeCrash = outcome.failedBeforeCrash
            observation.timedOut = false
            // Several tests were running (Swift Testing runs tests side by side): none is named as the one that crashed
            if outcome.crashedIn == nil, !outcome.runningAtStop.isEmpty { observation.limitNote = "running then: " + outcome.runningAtStop.prefix(5).joined(separator: ", ") }
        default:
            break
        }
        // A limit stopped the run after its tests had started. Before that is a Timeout: did the host crash? A crash
        // report written during the run says so, also when xcodebuild had not yet written that it starts the host
        // again (then the first crash would have stopped the run). Only looked for here, in a run that is about to
        // be a Timeout, so it costs a run that passes or fails nothing.
        if outcome.timedOut, outcome.watchLimit != "startup", outcome.watchLimit != "crash", !InterruptState.isInterrupted {
            let reports = SharedProcess.crashReports(bundleIdentifiers: Xcode.hostBundleIdentifiers(xctestrun: xctestrun), since: started,
                                                     device: xcode.simulatorUDID ?? SimulatorCheck.simulator(forDestination: xcode.options.destination)?.udid)
            // Without a crash report (one is not written for every crash, and on a busy Mac it can come late): the
            // host's own line that it terminates, when no test started or ended after it (`LogWatch.terminationLine`)
            let terminated = reports.isEmpty ? LogWatch.terminationLine(in: logText, hosts: Xcode.hostExecutableNames(xctestrun: xctestrun)) : nil
            if let terminated {
                observation.crashEvidence = "the test host wrote that it terminates, and no test started or ended after that: \"\(terminated)\"; xcodebuild had not started the host again when the run was stopped (\(observation.limitNote ?? "the limit of the run"))"
                observation.crashedIn = outcome.runningAtStop.count == 1 ? outcome.runningAtStop[0] : ""
                observation.failedBeforeCrash = observation.crashedIn.map { !$0.isEmpty && LogWatch.failed($0, in: logText) }
                observation.timedOut = false
                observation.stoppedInTest = nil
            } else if let report = reports.first {
                let what = SharedProcess.describeCrashReport(atPath: report).map { " (\($0))" } ?? ""
                observation.crashEvidence = "a crash report of the host was written during the run: \(report)\(what); xcodebuild had not started the host again when the run was stopped (\(observation.limitNote ?? "the limit of the run"))"
                observation.crashedIn = outcome.runningAtStop.count == 1 ? outcome.runningAtStop[0] : ""
                observation.failedBeforeCrash = observation.crashedIn.map { !$0.isEmpty && LogWatch.failed($0, in: logText) }
                observation.timedOut = false
                observation.stoppedInTest = nil
            }
        }
        return (observation, log.path)
    }
}

/// The record written by the test process (`R <ID>` = reached, `A <ID>` = evaluated as active).
enum Trace {
    static func read(_ url: URL) -> (reached: Set<Int>, activated: Set<Int>) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return ([], []) }
        var reached: Set<Int> = []
        var activated: Set<Int> = []
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ")
            guard parts.count == 2, let id = Int(parts[1]) else { continue }
            reached.insert(id)
            if parts[0] == "A" { activated.insert(id) }
        }
        return (reached, activated)
    }
}
