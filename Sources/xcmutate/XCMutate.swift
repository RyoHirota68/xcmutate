import ArgumentParser
import Foundation
import MutatorCore
import MutatorRunner

@main
struct XCMutate: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: ToolInfo.name,
        abstract: "Mutation testing for Swift and Xcode projects: find the changes to your code that your tests would not notice.",
        discussion: """
        Start with a run in the directory of a Swift package (`xcodebuild -list` shows the scheme):

          \(ToolInfo.name) run --package . --scheme <scheme> --destination 'platform=macOS'

        `\(ToolInfo.name) run --help` has the examples for an Xcode project and for the lines of a pull request.
        Documentation: \(Documentation.url)/getting-started.md
        """,
        version: ToolInfo.version,
        subcommands: [Run.self, List.self, InitCommand.self, Accept.self, Clean.self, AgentGuideCommand.self, Instrument.self]
    )

    /// As the default `main`, except for an error that a command raises while it runs (a file that does not exist,
    /// a name git does not know, a report that cannot be read): the message says what is wrong, and the usage of the
    /// command line, which ArgumentParser appends to every `ValidationError`, is not printed after it. A mistake in
    /// the options themselves (found while parsing and in `validate`) is still followed by the usage.
    static func main() {
        var command: ParsableCommand
        do {
            command = try parseAsRoot(try withProfile(rewrittenArguments(Array(CommandLine.arguments.dropFirst()))))
        } catch {
            exit(withError: error)
        }
        do {
            try command.run()
        } catch let error as ValidationError {
            FileHandle.standardError.write(Data("Error: \(error.message)\n".utf8))
            Foundation.exit(64)
        } catch {
            exit(withError: error)
        }
    }
}

/// The run options that came from the config file (`RunProfile`), for the record of the run.
nonisolated(unsafe) var profileExpansion = RunProfile.Expansion()

extension XCMutate {
    /// `run`: the run options of the config file (its `run` object and the profile named by `--profile`) put in front of
    /// the command line's, which therefore win. Other commands are left as they are.
    static func withProfile(_ arguments: [String]) throws -> [String] {
        // The help is shown whatever the config file holds
        guard arguments.first == "run", !arguments.contains("--help"), !arguments.contains("-h") else { return arguments }
        func value(of option: String) -> String? {
            for (index, argument) in arguments.enumerated() {
                if argument == "--" { break }
                if argument == option, index + 1 < arguments.count { return arguments[index + 1] }
                if argument.hasPrefix(option + "=") { return String(argument.dropFirst(option.count + 1)) }
            }
            return nil
        }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let root: URL
        if let given = value(of: "--root") {
            root = URL(fileURLWithPath: given, relativeTo: cwd).standardizedFileURL
        } else if let top = try? GitDiff.git(["rev-parse", "--show-toplevel"]).trimmingCharacters(in: .whitespacesAndNewlines), !top.isEmpty {
            root = URL(fileURLWithPath: top)
        } else {
            root = cwd
        }
        let config = try configFile(given: value(of: "--config"), root: root, cwd: cwd)
        do {
            profileExpansion = try RunProfile.expand(configAt: config, profile: value(of: "--profile"), given: arguments)
        } catch let failure as RunProfile.Failure {
            throw ValidationError(failure.description)
        }
        return ["run"] + profileExpansion.arguments + arguments.dropFirst()
    }

    /// `--shared-process auto` and `--shared-process=auto` become `--shared-process-auto`: a flag cannot take a value,
    /// and `--shared-process` alone keeps its meaning.
    static func rewrittenArguments(_ arguments: [String]) -> [String] {
        var result: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" {
                result += arguments[index...]
                break
            }
            if argument == "--shared-process=auto" {
                result.append("--shared-process-auto")
            } else if argument == "--shared-process", index + 1 < arguments.count, arguments[index + 1] == "auto" {
                result.append("--shared-process-auto")
                index += 1
            } else {
                result.append(argument)
            }
            index += 1
        }
        return result
    }
}

enum Documentation {
    /// Where the documentation of the published repository is.
    static let url = "https://github.com/RyoHirota68/xcmutate/blob/main/docs"
}

func warn(_ message: String) {
    FileHandle.standardError.write(Data("\(ToolInfo.name): warning: \(message)\n".utf8))
}

/// The config file: the one given with --config (relative to `cwd` when given), else the one at the root
/// (`ConfigFile.locate`: `xcmutate.yml`, or `xcmutate.config.json` of earlier versions; two of them stop the command).
func configFile(given: String?, root: URL, cwd: URL?) throws -> URL {
    if let given { return cwd.map { URL(fileURLWithPath: given, relativeTo: $0).standardizedFileURL } ?? URL(fileURLWithPath: given) }
    do {
        return try ConfigFile.locate(root: root)
    } catch let ambiguous as ConfigFile.Ambiguous {
        throw ValidationError(ambiguous.description)
    }
}

/// Reads the config file and prints warnings such as unknown keys to standard error.
func loadConfig(_ url: URL) throws -> MutatorConfig {
    do {
        let config = try MutatorConfig.load(url)
        for message in config.loadWarnings { warn(message) }
        return config
    } catch let error as MutatorConfig.ConfigError {
        throw ValidationError("\(error)")
    }
}

struct CommonOptions: ParsableArguments {
    @Option(help: "Only the mutants on lines changed since this git ref (for example origin/main). Uncommitted changes count.")
    var since: String?

    @Option(help: "Directory that file paths and stable keys are relative to, and where the config file is looked up (default: the git top-level directory of the current directory, as for run; the current directory outside git).")
    var root: String?

    @Option(help: "Maximum number of switches in one expression (default: 12, or the config file).")
    var maxSwitchesPerExpression: Int?

    @Option(help: "Call to leave alone (arid), in addition to \(MutatorConfig.defaultName) (repeatable). Matches the callee text, its prefix before '.' or '(', or the last name.")
    var arid: [String] = []

    @Option(help: "Operator to disable (repeatable), in addition to \(MutatorConfig.defaultName).")
    var disableOperator: [String] = []

    @Option(help: "Operator that is off by default to enable (repeatable), in addition to \(MutatorConfig.defaultName).")
    var enableOperator: [String] = []

    @Option(help: "Config file (default: <root>/\(MutatorConfig.defaultName), or \(ConfigFile.jsonName) of versions up to 0.14). A path ending in .json is read as JSON, any other as YAML.")
    var config: String?

    @Argument(help: "Swift files to look at. list: may be left out with --since (the changed files that run would mutate are taken).")
    var files: [String] = []

    func generatorOptions() throws -> GeneratorOptions {
        let url = try configFile(given: config, root: rootURL, cwd: nil)
        return try loadConfig(url).generatorOptions(extraArid: arid, extraDisabled: disableOperator, maxSwitches: maxSwitchesPerExpression, extraEnabled: enableOperator)
    }

    /// As for `run`: the directory given with --root, else the top level of the git repository that holds the current
    /// directory, else the current directory. (With another default than `run`, `list` in a subdirectory would not
    /// read the project's config file, and would print keys that `run` does not know.)
    var rootURL: URL {
        if let root { return URL(fileURLWithPath: root).standardizedFileURL }
        if let top = try? GitDiff.git(["rev-parse", "--show-toplevel"]).trimmingCharacters(in: .whitespacesAndNewlines), !top.isEmpty {
            return URL(fileURLWithPath: top).standardizedFileURL
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).standardizedFileURL
    }

    func relativePath(_ file: String) -> String {
        let path = Paths.canonical(URL(fileURLWithPath: file))
        let rootPath = Paths.canonical(rootURL) + "/"
        return path.hasPrefix(rootPath) ? String(path.dropFirst(rootPath.count)) : URL(fileURLWithPath: file).standardizedFileURL.path
    }

    /// `--package <dir>` of `list`, as `run` takes it: a subdirectory of the root limits the files chosen by `--since`
    /// to that directory (without --root and without file arguments). Nil when there is nothing to narrow.
    func packageDirectory(_ package: String?) throws -> String? {
        guard let package, root == nil, files.isEmpty else { return nil }
        let url = URL(fileURLWithPath: package, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).standardizedFileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ValidationError("--package \(package) does not exist (looked for \(url.path); paths are relative to the current directory)")
        }
        let relative = relativePath(url.path)
        return relative.isEmpty || relative == "." || relative.hasPrefix("/") ? nil : relative
    }

    /// Processes all files. IDs are sequential from 0 across files.
    /// - Parameter packageDirectory: from `packageDirectory(_:)`: the files that --since chooses are those below it.
    func processAll(packageDirectory: String? = nil) throws -> [FileResult] {
        let changed = try since.map { try GitDiff.changedLines(since: $0, root: rootURL) }
        var files = files
        if files.isEmpty {
            // Without files, --since chooses them as `run --since` does: the Swift files that git knows, minus tests,
            // generated code and the `exclude` patterns, of which those that changed
            guard let since, let changed else {
                throw ValidationError("Name the Swift files to look at, or give --since <ref> to take the files that changed since that commit.")
            }
            let configURL = try configFile(given: config, root: rootURL, cwd: nil)
            var selection: FileSelector.Selection
            do {
                selection = try WorkCopyFiles.select(root: rootURL, patterns: try loadConfig(configURL).exclude ?? [])
            } catch let error as ValidationError {
                throw error
            } catch {
                throw ValidationError("\(rootURL.path) is not inside a git repository, so there is no list of tracked files to choose from. Name the Swift files as arguments.")
            }
            if let packageDirectory { selection = selection.narrowed(to: packageDirectory) }
            files = selection.included.map { rootURL.appendingPathComponent($0).path }
                .filter { changed[URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path] != nil }
            if files.isEmpty { warn("--since \(since): no Swift file that would be mutated has changed under \(packageDirectory.map { rootURL.appendingPathComponent($0).path } ?? rootURL.path).") }
        }
        var options = try generatorOptions()
        OperatorDeclarationSources.apply(to: &options, root: rootURL, extraFiles: files)
        let processor = FileProcessor(options: options)
        var results: [FileResult] = []
        var nextID = 0
        for file in files {
            let source: String
            do {
                source = try SourceText.read(URL(fileURLWithPath: file))
            } catch let error as SourceText.NotUTF8 {
                throw ValidationError(error.description)
            } catch {
                throw ValidationError("\(file) cannot be read: \(error.localizedDescription)")
            }
            var lines: [ClosedRange<Int>]?
            if let changed {
                let absolute = URL(fileURLWithPath: file).standardizedFileURL.resolvingSymlinksInPath().path
                lines = changed[absolute] ?? []
            }
            let result = processor.process(source: source, file: relativePath(file), firstID: nextID, changedLines: lines)
            for warning in result.warnings { warn("\(result.file):\(warning.line): \(warning.message)") }
            nextID += result.mutants.count
            results.append(result)
        }
        return results
    }
}

enum OutputFormat: String, ExpressibleByArgument {
    case text, json
}

struct List: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List the mutants of some files, without running.",
        discussion: """
        Nothing is built or run. Use it to see how many mutants a change has before a run, or to look up stable keys.

        Examples:
          \(ToolInfo.name) list --since origin/main
          \(ToolInfo.name) list --since origin/main --package Shop
          \(ToolInfo.name) list --keys Sources/App/Cart.swift
        """)

    @OptionGroup var common: CommonOptions

    @Option(help: "The --package of the run: a subdirectory limits the files that --since chooses to that directory, as run does (without --root and without file arguments). Paths and keys stay relative to the root.")
    var package: String?

    @Option(help: "Output format.")
    var format: OutputFormat = .text

    @Flag(help: "Also list ignored candidates (text format).")
    var showIgnored = false

    @Flag(name: .customLong("keys"), help: "Text format: end every line with the stable key of the mutant (what run --only and accept take).")
    var showKeys = false

    func run() throws {
        let results = try common.processAll(packageDirectory: try common.packageDirectory(package))
        switch format {
        case .json:
            try printJSON(Manifest(results: results))
        case .text:
            for r in results {
                if let reason = r.skippedReason {
                    print("\(r.file): skipped (\(reason))")
                    continue
                }
                for m in r.mutants {
                    print("\(m.file):\(m.start.line):\(m.start.column): [\(m.id)] \(m.operator.rawValue) `\(m.original)` -> `\(m.replacement)`  (\(m.enclosingDecl))" + (showKeys ? "  \(m.key)" : ""))
                }
                if showIgnored {
                    for i in r.ignored {
                        print("\(i.file):\(i.start.line):\(i.start.column): [ignored: \(i.reason.rawValue)] \(i.operator.rawValue) `\(i.original)` -> `\(i.replacement)`")
                    }
                }
            }
            let total = results.reduce(0) { $0 + $1.mutants.count }
            let ignored = results.reduce(0) { $0 + $1.ignored.count }
            print("\(total) mutants, \(ignored) ignored, \(results.count) files" + (ignored > 0 && !showIgnored ? " (--show-ignored lists the ignored candidates and why)" : ""))
        }
    }
}

/// `xcmutate agent-guide`: the procedure for coding agents, as text on standard output. It reads nothing (no
/// project, no git, no file): the text is compiled in, so it is that of the installed version.
struct AgentGuideCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "agent-guide",
        abstract: "Print the procedure for coding agents.",
        discussion: """
        The procedure: find the gaps, write tests, check again. Without options the command prints the guide for a \
        coding agent that is asked to close the gaps in a project's tests. The text is compiled into the tool, so it \
        matches the installed version, and no project is needed.

        With --install it writes the file through which an agent finds the guide by itself, at the root of the git \
        repository that holds the current directory (the current directory outside a repository). It looks at the \
        project to decide what to write:
          a .claude/ folder   the Claude Code skill (.claude/skills/mutation-test-loop/SKILL.md)
          an .agents/ folder  the Codex skill (.agents/skills/mutation-test-loop/SKILL.md)
          an AGENTS.md        a section in it, between two marker comments; the rest of the file is not touched
          several of these    each of them
          none of these       a new AGENTS.md
        Without a .claude/ folder it also prints how to add the Claude Code skill.
        A second run replaces only the tool's own parts and changes nothing when they are up to date.

        --install-for <target> writes one target instead:
        \(AgentInstall.targetList)

        Examples:
          \(ToolInfo.name) agent-guide
          \(ToolInfo.name) agent-guide --install
          \(ToolInfo.name) agent-guide --install-for claude
          \(ToolInfo.name) agent-guide --install-for claude --user
        """)

    @Flag(help: "Write the file through which an agent finds the guide, chosen from what the project has (.claude/, .agents/, AGENTS.md), instead of printing the guide.")
    var install = false

    @Option(name: .customLong("install-for"), help: ArgumentHelp("Write one target instead of the ones --install chooses: claude, codex or agents-md.", valueName: "target"))
    var installFor: String?

    @Flag(help: "With --install-for claude or codex: write the skill to your home directory (~/.claude/skills or ~/.agents/skills), for all your projects, instead of the repository.")
    var user = false

    @Flag(help: "With --install or --install-for: replace a skill file that differs from what the tool writes. Without it such a file is left alone.")
    var force = false

    func validate() throws {
        if user, installFor == nil {
            throw ValidationError("--user needs a target: \(ToolInfo.name) agent-guide --install-for claude --user (or codex). --install alone writes only into the project.")
        }
        if force, !install, installFor == nil { throw ValidationError("--force belongs to --install or --install-for <target>.") }
    }

    func run() throws {
        guard install || installFor != nil else {
            FileHandle.standardOutput.write(Data(AgentGuide.text.utf8))
            return
        }
        var root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).standardizedFileURL
        if let top = try? GitDiff.git(["rev-parse", "--show-toplevel"]).trimmingCharacters(in: .whitespacesAndNewlines), !top.isEmpty {
            root = URL(fileURLWithPath: top).standardizedFileURL
        }
        let home = URL(fileURLWithPath: ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory())
        let detection = installFor == nil ? AgentInstall.detect(root: root) : nil
        let names = installFor.map { [$0] } ?? detection?.targets ?? []
        var failed: AgentInstall.Failure?
        for name in names {
            do {
                let result = try AgentInstall.install(name, root: root, home: home, user: user, force: force)
                let line = AgentInstall.message(result.outcome, target: result.target, found: detection.map { AgentInstall.reason(name, $0) }, root: user ? nil : root)
                FileHandle.standardOutput.write(Data((line + "\n").utf8))
            } catch let failure as AgentInstall.Failure {
                FileHandle.standardError.write(Data("Error: \(failure.description)\n".utf8))
                failed = failed ?? failure
            }
        }
        if let detection, !detection.claudeFolder, failed == nil {
            FileHandle.standardOutput.write(Data((AgentInstall.claudeHint + "\n").utf8))
        }
        if let failed {
            if case .unknownTarget = failed { throw ExitCode(64) }
            throw ExitCode(ExitCodes.infrastructure)
        }
    }
}

struct Instrument: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "For diagnosing the tool: write instrumented files.",
        discussion: """
        `run` does this itself in its work copy. Use this command to look at what the tool makes of a file: every \
        mutant embedded behind a switch that is off, and a static check of the result.

        Example:
          \(ToolInfo.name) instrument --output-dir /tmp/instrumented Sources/App/Cart.swift
        """)

    @OptionGroup var common: CommonOptions

    @Flag(help: "Overwrite the input files.")
    var inPlace = false

    @Option(help: "Write instrumented files under this directory, keeping paths relative to --root.")
    var outputDir: String?

    @Option(help: "Write the mutant manifest (JSON) to this path.")
    var manifest: String?

    func validate() throws {
        if inPlace == (outputDir != nil) {
            throw ValidationError("Specify exactly one of --in-place or --output-dir.")
        }
        if common.files.isEmpty { throw ValidationError("Missing expected argument '<files> ...'") }
    }

    func run() throws {
        let results = try common.processAll()
        var failed = false
        for r in results {
            if !r.verification.isValid {
                failed = true
                FileHandle.standardError.write(Data("verification failed: \(r.file): \(r.verification.problems.joined(separator: "; "))\n".utf8))
                continue
            }
            let destination: URL
            if inPlace {
                destination = common.rootURL.appendingPathComponent(r.file)
            } else {
                destination = URL(fileURLWithPath: outputDir!).appendingPathComponent(r.file)
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            }
            try SourceText.write(r.instrumented, to: destination)
        }
        if let manifest {
            let data = try JSONEncoder.pretty.encode(Manifest(results: results))
            try data.write(to: URL(fileURLWithPath: manifest))
        }
        let total = results.reduce(0) { $0 + $1.mutants.count }
        print("instrumented \(total) mutants in \(results.count) files")
        if failed { throw ExitCode(2) }
    }
}

struct Manifest: Encodable {
    struct FileEntry: Encodable {
        var file: String
        var skippedReason: String?
        var outOfDiffCount: Int
        var verification: VerificationResult
        var mutants: [Mutant]
        var ignored: [IgnoredMutant]
    }

    var environmentVariable = Instrumenter.environmentVariable
    var files: [FileEntry]

    init(results: [FileResult]) {
        files = results.map {
            FileEntry(file: $0.file, skippedReason: $0.skippedReason, outOfDiffCount: $0.outOfDiffCount,
                      verification: $0.verification, mutants: $0.mutants, ignored: $0.ignored)
        }
    }
}

extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

extension JSONEncoder {
    static var compact: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

func printJSON(_ value: some Encodable) throws {
    let data = try JSONEncoder.pretty.encode(value)
    print(String(decoding: data, as: UTF8.self))
}

enum GitDiff {
    /// What `--since` found: the changed lines per absolute path, and the files whose changes git does not show in a diff.
    struct Changes {
        var lines: [String: [ClosedRange<Int>]] = [:]
        /// Files that count as changed in every line for a reason other than being new, with the reason.
        var wholeFiles: [String: String] = [:]
    }

    /// Options that make the output of git the same whatever the user's configuration: `diff.mnemonicPrefix`,
    /// `diff.noprefix`, `diff.relative`, `core.quotePath`, external diff drivers and text conversion, colour.
    static let stableOutput = ["-c", "core.quotePath=false", "-c", "diff.mnemonicPrefix=false", "-c", "diff.noprefix=false", "-c", "color.ui=false"]

    /// Turns the diff from the fork point (merge-base) of `<ref>` and HEAD to the working tree into changed line ranges per absolute path
    /// (including uncommitted changes and untracked files). git is run against the repository at `root`.
    static func changedLines(since ref: String, root: URL) throws -> [String: [ClosedRange<Int>]] {
        try changes(since: ref, root: root).lines
    }

    static func changes(since ref: String, root: URL) throws -> Changes {
        // --since compares with a commit: outside a repository there is nothing to compare with. Said in those
        // words, not as the git command that failed
        guard let top = (try? git(["-C", root.path, "rev-parse", "--show-toplevel"]))?.trimmingCharacters(in: .whitespacesAndNewlines), !top.isEmpty else {
            throw ValidationError("--since \(ref): \(root.path) is not inside a git repository, so there is no commit to compare with. Leave --since out to mutate whole files (and name the files, since there is no list of tracked files either), or run `git init` and commit first.")
        }
        // Diff against the fork point (even if `origin/main` has moved ahead, lines you did not touch are not included)
        // A name that git does not know is a mistake of the caller; say that, not which git command failed
        guard (try? git(["rev-parse", "--verify", "--quiet", ref + "^{commit}"], cwd: top)) != nil else {
            throw ValidationError("--since \(ref): git knows no commit of that name in \(top) (a branch that was not fetched, or a typing error; `git branch -a` lists the branches).")
        }
        let base = (try? git(["merge-base", ref, "HEAD"], cwd: top).trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? ref
        // --text: a file that `.gitattributes` marks `-diff` (binary) is compared as text all the same
        let diff = try git(stableOutput + ["diff", "--unified=0", "--no-color", "--no-ext-diff", "--no-textconv", "--text", "--no-relative",
                                           "--src-prefix=a/", "--dst-prefix=b/", base, "--", "*.swift"], cwd: top)
        var result = Changes()
        func absolute(_ path: String) -> String {
            URL(fileURLWithPath: top).appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath().path
        }
        for (path, ranges) in DiffFilter.parseUnifiedDiff(diff) { result.lines[absolute(path)] = ranges }
        // All lines of untracked files are treated as changed.
        let untracked = try git(stableOutput + ["ls-files", "-z", "--others", "--exclude-standard", "--", "*.swift"], cwd: top)
        for path in untracked.split(separator: "\0") where !path.isEmpty { result.lines[absolute(String(path))] = [1...Int.max] }
        // `git diff` leaves out the changes of files marked assume-unchanged or skip-worktree (`git update-index`).
        // The work copy holds their changed text all the same, so they are compared here: changed means every line.
        let flagged = (try? git(stableOutput + ["ls-files", "-z", "-v", "--", "*.swift"], cwd: top)) ?? ""
        for entry in flagged.split(separator: "\0") {
            guard let tag = entry.first, entry.count > 2, tag.isLowercase || tag == "S" else { continue }
            let path = String(entry.dropFirst(2))
            let current = FileManager.default.contents(atPath: absolute(path))
            let earlier = try? gitData(["show", "\(base):\(path)"], cwd: top)
            if current != earlier, current != nil {
                result.lines[absolute(path)] = [1...Int.max]
                result.wholeFiles[absolute(path)] = "git hides its changes (assume-unchanged or skip-worktree), so every line counts as changed"
            }
        }
        return result
    }

    static func gitData(_ arguments: [String], cwd: String? = nil) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ValidationError("git \(arguments.joined(separator: " ")) failed with status \(process.terminationStatus)") }
        return data
    }

    static func git(_ arguments: [String], cwd: String? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        let pipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = pipe
        process.standardError = errorPipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw ValidationError("git \(arguments.joined(separator: " ")) failed with status \(process.terminationStatus)" + (message.isEmpty ? "" : ": \(message)"))
        }
        return String(decoding: data, as: UTF8.self)
    }
}

/// `run`: the options under the heading "What to mutate" of its help.
struct TargetOptions: ParsableArguments {
    @Argument(help: "Swift files to mutate (relative to the current directory). Default: every Swift file that git knows, minus tests, generated code and the `exclude` patterns.")
    var files: [String] = []

    @Option(help: "Mutate only the lines changed since this git ref (for example origin/main). Uncommitted changes and untracked files count.")
    var since: String?

    @Option(help: "Run only the mutants with these stable keys (repeatable). The keys are in every report.")
    var only: [String] = []

    @Option(help: "Leave these files out (repeatable, gitignore-style glob; a leading ! includes again). Adds to `exclude` in \(MutatorConfig.defaultName).")
    var exclude: [String] = []

    @Option(help: "Directory that is copied and mutated. Default: the top level of the git repository that holds the current directory.")
    var root: String?
}

/// `run`: the options under the heading "How to build and test" of its help.
struct ProjectOptions: ParsableArguments {
    @Option(help: "Swift package directory (for example `.`). Give exactly one of --package, --project, --workspace. A subdirectory of the repository limits the default files to mutate to that directory (without --root and without file arguments); paths and keys stay relative to the root. If the directory also has an .xcodeproj, remove it in the work copy with --prepare.")
    var package: String?

    @Option(help: "Xcode project (relative to the current directory).")
    var project: String?

    @Option(help: "Xcode workspace (relative to the current directory).")
    var workspace: String?

    @Option(help: "Scheme to build and test. `xcodebuild -list` shows the schemes. For a Swift package it is the name of its one product, or <name>-Package when the package declares no product or several.")
    var scheme: String?

    @Option(help: "Where the tests run, as for xcodebuild -destination: 'platform=macOS', or a booted simulator as 'id=<UDID>'. Repeat it to run mutants on several destinations at the same time; the build and the baseline use the first.")
    var destination: [String] = []

    @Option(help: "Run only these tests (repeatable; passed as -only-testing:). Use it to leave out UI test targets.")
    var onlyTesting: [String] = []

    @Option(help: "Do not run these tests (repeatable; passed as -skip-testing:).")
    var skipTesting: [String] = []

    @Option(help: "Test plan to use.")
    var testPlan: String?

    @Option(help: "Run only this configuration of the test plan (repeatable). A plan with several configurations runs the tests once per configuration for every mutant.")
    var onlyTestConfiguration: [String] = []

    @Option(help: "Shell command to run in the work copy before the build (for example 'xcodegen generate'). Files that git ignores are not in the copy; create them here.")
    var prepare: String?

    @Option(parsing: .singleValue, help: "Extra argument for the build (repeatable; write it as --build-arg=-quiet).")
    var buildArg: [String] = []

    @Option(parsing: .singleValue, help: "Extra argument for every test run (repeatable; write it as --test-arg=<argument>).")
    var testArg: [String] = []

    @Flag(help: "Keep the project's \"warnings as errors\" setting. By default the build turns it off, because embedded mutants can produce warnings.")
    var keepWarningsAsErrors = false

    @Option(help: "A SourcePackages directory to copy into the work directory before the first build, so that packages are not fetched again.")
    var packageCache: String?
}

/// `run`: the options under the heading "Making it faster" of its help.
struct SpeedOptions: ParsableArguments {
    @Flag(help: "Run many mutants in one test process instead of starting the tests once per mutant. Usually several times faster with the same verdicts: a mutant is judged there only when its tests fail and then pass again without it, and the others are run again in a process of their own. Not used for UI test targets (a warning says so). `--shared-process auto` uses shared processes only when the baseline's times say that they save time for the number of mutants (the run says which it chose, and why).")
    var sharedProcess = false

    /// `--shared-process auto`, rewritten to this by `XCMutate.rewrittenArguments` (ArgumentParser has no flag with an optional value).
    @Flag(name: .customLong("shared-process-auto"), help: .hidden)
    var sharedProcessAuto = false

    @Option(help: "Which tests each mutant runs: none (all of them, the default), reach (only the suites that execute the mutated code, found in the baseline) auto (tests named after the mutated file, Foo.swift -> FooTests) or impact (the suites that an impact map of an earlier run says ran the files changed since, then as reach; needs --impact-map). Use reach when one run of all tests takes more than a few seconds.")
    var selectTests: TestSelectionMode = .none

    @Option(help: "Number of destinations that run mutants at the same time. Default: the number of --destination options. If it is larger and the first destination is a simulator, the tool creates the missing simulators (\(SimulatorWorkers.namePrefix)<pid>-w<n>) and deletes them at the end.")
    var workers: Int?

    @Flag(help: "Skip mutants that an earlier run with --reuse in the same work directory found Killed, as long as nothing their result rests on has changed. Reused results are marked in the report; a run without the option remains the reference.")
    var reuse = false

    @Flag(name: .customLong("no-stop-at-first-failure"), help: "With --shared-process: run a mutant that runs by itself against all selected tests to the end under xcodebuild. By default such a run goes to the tool's driver and stops at its first failing test, which is enough for Killed.")
    var noStopAtFirstFailure = false

    @Flag(name: .customLong("no-narrow-gate"), help: "With --shared-process and --select-tests reach: make both runs without mutants at the start of a shared process of all selected tests. By default the second runs only the suites that the process's mutants reach.")
    var noNarrowGate = false

    @Flag(name: .customLong("no-direct-launch"), help: "With --shared-process: let xcodebuild start every test process. By default the tool starts the test host itself where that is safe (faster), and falls back to xcodebuild with a warning when the tests do not pass in a host it started.")
    var noDirectLaunch = false
}

/// `run`: the options under the heading "How verdicts are checked" of its help.
struct VerdictOptions: ParsableArguments {
    @Option(help: "How a failing run is confirmed as the mutant's effect and not that of state an earlier run left behind: auto (the default), all (repeat more failing runs), full (with --select-tests reach, also run every detected mutant against all tests: one more run per detected mutant), restore (as auto, but on an iOS simulator the run without mutants after a failing run is replaced by putting back a copy of the app's containers and the keychain taken before the baseline; it assumes tests that depend on nothing outside the simulator) or none (no confirmation: a failing run counts as it is, which can report mutants as Killed that are not).")
    var confirmKills: KillConfirmation = .auto

    @Flag(inversion: .prefixedNo, help: "With --select-tests reach: run a mutant that passes the tests that reach it once more against all tests before it is reported as Survived (on by default). --no-recheck-survivors skips that run: faster, but a mutant that only a test of another suite would catch is then reported as Survived (marked `narrowedOnly`).")
    var recheckSurvivors: Bool?

    @Flag(help: "With --shared-process: skip the second run of a mutant whose tests passed in a shared process and report it as Survived. Faster, but state left in the process by earlier runs can hide a failure, so some of those Survived are wrong.")
    var trustSharedSurvivors = false

    @Option(help: "A mutant's run may take the baseline's time x this factor + --timeout-constant before it is a Timeout.")
    var timeoutFactor: Double = 3

    @Option(help: "Seconds added to every timeout.")
    var timeoutConstant: Double = 30

    @Option(help: "File of mutants accepted as equivalent (default: <root>/\(AcceptedFile.defaultName)). `\(ToolInfo.name) accept` writes it.")
    var accepted: String?
}

/// `run`: the options under the heading "Reports and CI gates" of its help.
struct ReportOptions: ParsableArguments {
    @Option(help: "Report format (repeatable): text (the default), json, agent, markdown, html, stryker, xcode, github. agent, xcode and github print to standard output (text then goes to standard error); the others write a file under <work-dir>/report/ unless --report gives a path.")
    var reporter: [String] = ["text"]

    @Option(help: "Write a report to a path, as <format>:<path> (repeatable; '-' is standard output). Example: --report html:out/mutation.html")
    var report: [String] = []

    @Option(help: "Path of the JSON report. Same as --report json:<path>.")
    var jsonOutput: String?

    @Option(help: "With --select-tests reach: write which suites ran the code of which file (an impact map, JSON) for later runs with --select-tests impact. Meant for a nightly run of whole files on the main branch.")
    var writeImpactMap: String?

    @Option(help: "With --select-tests impact: the impact map of an earlier run (--write-impact-map). The run selects the suites that ran the files changed since the map's commit, and the suites of changed test files; the results hold among those suites.")
    var impactMap: String?

    @Option(help: "Write the progress of the run to this file while it runs, one JSON object per line: phases, a heartbeat when nothing else happens for a minute, each mutant's result with the time left, and the exit code at the end. A program or a coding agent can follow it (docs/reports.md). With --resume the lines are appended.")
    var progressFile: String?

    @Flag(help: "Exit with status 3 if any mutant was not detected (Survived or NotReached; accepted mutants do not count).")
    var failOnSurvived = false

    @Option(help: "Exit with status 4 if the mutation score in percent is below this value.")
    var failUnder: Double?

    @Flag(help: "Stop as soon as the result of the gates (--fail-on-survived, --fail-under, --baseline-report) can no longer change, whatever the mutants still to come give. The report covers what was run and says so; the exit code is the gate's. --resume can go on.")
    var stopWhenGateDecided = false

    @Option(name: [.customLong("baseline-report"), .customLong("baseline")],
help: "JSON report of an earlier run (for example of the main branch). Exit with status 5 if a mutant is undetected now and was not undetected then: \"no new gaps\".")
    var baselineReport: String?
}

/// `run`: the options under the heading "Limits and resuming" of its help.
struct LimitOptions: ParsableArguments {
    @Option(help: "Examine at most this many mutants. With more, a sample is chosen by the stable keys (the same sources give the same sample), and the report says how many were left out.")
    var maxMutants: Int?

    @Option(help: "Stop after this time (90s, 45m, 2h, 1h30m; a bare number is seconds) and report the mutants that have a verdict; the others are listed as not run. --resume continues such a run.")
    var timeLimit: String?

    @Flag(help: "Continue the earlier run in the same work directory: only the mutants without a result are run. Refused if the sources, the options or the tool version changed.")
    var resume = false
}

/// `run`: the options under the heading "Work directory and other" of its help.
struct OtherOptions: ParsableArguments {
    @Option(help: "Work directory: the copy of the sources, the build, logs and reports (default: ~/Library/Caches/\(ToolNaming.cacheDirectoryName)/<hash of root>.noindex). `\(ToolInfo.name) clean` removes it.")
    var workDir: String?

    @Option(help: "What is copied into the work directory: git-root (the whole repository, so that references to files outside --root still resolve) or root (only --root).")
    var copyScope: CopyScope = .gitRoot

    @Option(help: "Config file (default: <root>/\(MutatorConfig.defaultName), or \(ConfigFile.jsonName) of versions up to 0.14). A path ending in .json is read as JSON, any other as YAML.")
    var config: String?

    @Option(help: "Use the run options of this profile of the config file (`profiles.<name>`), on top of its `run` options. Options on the command line win. The keys: \(ConfigFile.runOptionsDocumentation)")
    var profile: String?

    @Option(help: "Turn a mutation operator off (repeatable). Adds to \(MutatorConfig.defaultName).")
    var disableOperator: [String] = []

    @Option(help: "Turn on an operator that is off by default (repeatable). Adds to \(MutatorConfig.defaultName).")
    var enableOperator: [String] = []

    @Option(help: "Never remove or change calls to this function (repeatable; for logging and the like). Adds to \(MutatorConfig.defaultName).")
    var arid: [String] = []

    @Option(help: "Maximum number of mutants embedded in one expression (default: 12, or the config file).")
    var maxSwitchesPerExpression: Int?

    @Option(help: "Maximum number of rebuilds after leaving out mutants that do not compile.")
    var maxRebuilds: Int = 5

    @Option(help: "Maximum number of builds used to find mutants that do not compile when the compiler does not point at them.")
    var maxBisectBuilds: Int = 16

    @Flag(help: "Keep the .xcresult bundle of every mutant's run.")
    var keepResults = false

    @Flag(help: "Do not keep the Mac awake during the run (by default `caffeinate -i` runs for as long as the run).")
    var noCaffeinate = false
}

struct Run: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Mutate the sources, build once, test each mutant.",
        discussion: """
        Runs mutation testing. The work happens in a copy of the repository (sources, build, logs, reports), \
        so your working tree is never modified. The report lists \
        the mutants that no test detected, each with a stable key for --only and for `\(ToolInfo.name) accept`.

        A Swift package on macOS:
          \(ToolInfo.name) run --package . --scheme <scheme> --destination 'platform=macOS'

        Only the lines changed since a branch (what you want for a pull request):
          \(ToolInfo.name) run --since origin/main --package . --scheme <scheme> \\
            --destination 'platform=macOS'

        An app whose unit tests run on an iOS simulator (boot it first: xcrun simctl boot <UDID>):
          \(ToolInfo.name) run --since origin/main --project App.xcodeproj --scheme App \\
            --destination 'id=<UDID>' --only-testing AppTests --shared-process

        Every option is described in \(Documentation.url)/usage.md
        """)

    @OptionGroup(title: "What to mutate") var target: TargetOptions
    var files: [String] { target.files }
    var since: String? { target.since }
    var only: [String] { target.only }
    var exclude: [String] { target.exclude }
    var root: String? { target.root }

    @OptionGroup(title: "How to build and test") var projectOptions: ProjectOptions
    var package: String? { projectOptions.package }
    var project: String? { projectOptions.project }
    var workspace: String? { projectOptions.workspace }
    var scheme: String? { projectOptions.scheme }
    var destination: [String] { projectOptions.destination }
    var onlyTesting: [String] { projectOptions.onlyTesting }
    var skipTesting: [String] { projectOptions.skipTesting }
    var testPlan: String? { projectOptions.testPlan }
    var onlyTestConfiguration: [String] { projectOptions.onlyTestConfiguration }
    var prepare: String? { projectOptions.prepare }
    var buildArg: [String] { projectOptions.buildArg }
    var testArg: [String] { projectOptions.testArg }
    var keepWarningsAsErrors: Bool { projectOptions.keepWarningsAsErrors }
    var packageCache: String? { projectOptions.packageCache }

    @OptionGroup(title: "Making it faster") var speed: SpeedOptions
    /// `--shared-process`, or `--shared-process auto` (which decides later whether they are used).
    var sharedProcess: Bool { speed.sharedProcess || speed.sharedProcessAuto }
    var selectTests: TestSelectionMode { speed.selectTests }
    var workers: Int? { speed.workers }
    var reuse: Bool { speed.reuse }
    var noDirectLaunch: Bool { speed.noDirectLaunch }

    @OptionGroup(title: "How verdicts are checked") var verdicts: VerdictOptions
    var confirmKills: KillConfirmation { verdicts.confirmKills }
    var recheckSurvivors: Bool? { verdicts.recheckSurvivors }
    var trustSharedSurvivors: Bool { verdicts.trustSharedSurvivors }
    var timeoutFactor: Double { verdicts.timeoutFactor }
    var timeoutConstant: Double { verdicts.timeoutConstant }
    var accepted: String? { verdicts.accepted }

    @OptionGroup(title: "Reports and CI gates") var reports: ReportOptions
    var reporter: [String] { reports.reporter }
    var report: [String] { reports.report }
    var jsonOutput: String? { reports.jsonOutput }
    var failOnSurvived: Bool { reports.failOnSurvived }
    var failUnder: Double? { reports.failUnder }
    var baselineReport: String? { reports.baselineReport }

    @OptionGroup(title: "Limits and resuming") var limits: LimitOptions
    var maxMutants: Int? { limits.maxMutants }
    var timeLimit: String? { limits.timeLimit }
    var resume: Bool { limits.resume }

    @OptionGroup(title: "Work directory and other") var other: OtherOptions
    var workDir: String? { other.workDir }
    var copyScope: CopyScope { other.copyScope }
    var config: String? { other.config }
    var disableOperator: [String] { other.disableOperator }
    var enableOperator: [String] { other.enableOperator }
    var arid: [String] { other.arid }
    var maxSwitchesPerExpression: Int? { other.maxSwitchesPerExpression }
    var maxRebuilds: Int { other.maxRebuilds }
    var maxBisectBuilds: Int { other.maxBisectBuilds }
    var keepResults: Bool { other.keepResults }
    var noCaffeinate: Bool { other.noCaffeinate }

    func validate() throws {
        if [project, workspace, package].compactMap({ $0 }).count != 1 {
            throw ValidationError("Say what to build with exactly one of --package, --project or --workspace. For a Swift package in the current directory: \(ToolInfo.name) run --package . --scheme <scheme> --destination 'platform=macOS'")
        }
        if package != nil, scheme == nil { throw ValidationError("--package needs --scheme (the name of the package's one product, or <name>-Package when the package declares no product or several; `xcodebuild -list` in the package directory shows the schemes).") }
        if package == nil, scheme == nil { throw ValidationError("--project and --workspace need --scheme (`xcodebuild -list -project <project>` shows the schemes).") }
        if destination.isEmpty { throw ValidationError("Say where the tests run with --destination: 'platform=macOS', or a booted simulator as 'id=<UDID>' (xcrun simctl list devices shows them).") }
        if let workers, workers < 1 { throw ValidationError("--workers takes a number of 1 or more.") }
        if let workers, workers < destination.count { throw ValidationError("--workers (\(workers)) is smaller than the number of --destination options (\(destination.count)).") }
        if trustSharedSurvivors, !sharedProcess { throw ValidationError("--trust-shared-survivors needs --shared-process.") }
        if noDirectLaunch, !sharedProcess { throw ValidationError("--no-direct-launch needs --shared-process.") }
        if speed.noStopAtFirstFailure, !sharedProcess { throw ValidationError("--no-stop-at-first-failure needs --shared-process.") }
        if speed.noNarrowGate, !sharedProcess || !selectTests.narrowsByReach { throw ValidationError("--no-narrow-gate needs --shared-process and --select-tests reach.") }
        if let recheckSurvivors, !selectTests.narrowsByReach { throw ValidationError("--\(recheckSurvivors ? "" : "no-")recheck-survivors needs --select-tests reach.") }
        _ = try reportOutputs(workURL: URL(fileURLWithPath: "/"), cwd: URL(fileURLWithPath: "/"))
        if selectTests == .impact, reports.impactMap == nil { throw ValidationError("--select-tests impact needs --impact-map <file> (written by an earlier run with --write-impact-map).") }
        if reports.impactMap != nil, selectTests != .impact { throw ValidationError("--impact-map needs --select-tests impact.") }
        if selectTests == .impact, !onlyTesting.isEmpty { throw ValidationError("--select-tests impact chooses the tests itself; leave out --only-testing (use --skip-testing to leave tests out).") }
        if reports.writeImpactMap != nil, selectTests != .reach { throw ValidationError("--write-impact-map needs --select-tests reach (the per-test record of the baseline).") }
        if reports.stopWhenGateDecided, !failOnSurvived, failUnder == nil, reports.baselineReport == nil {
            throw ValidationError("--stop-when-gate-decided needs a gate: --fail-on-survived, --fail-under or --baseline-report.")
        }
        if let failUnder, !(0...100).contains(failUnder) { throw ValidationError("--fail-under takes a percentage between 0 and 100.") }
        if let maxMutants, maxMutants < 1 { throw ValidationError("--max-mutants takes a number of 1 or more.") }
        if let timeLimit, TimeLimit.parse(timeLimit) == nil { throw ValidationError("--time-limit takes a duration such as 90s, 45m, 2h or 1h30m (a bare number is seconds), got \(timeLimit).") }
    }

    /// Mistakes in what the user wrote (an operator name that does not exist) are usage errors: exit status 64, not 1.
    static func usage<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as MutatorConfig.ConfigError {
            throw ValidationError(error.description)
        }
    }

    static let formats = ["text", "json", "agent", "xcode", "github", "markdown", "html", "stryker"]
    static let defaultFileNames = ["json": "mutation.json", "markdown": "mutation.md", "html": "mutation.html", "stryker": "mutation-stryker.json"]

    /// Which format goes where. A nil path means standard output (text goes to standard error when another format uses standard output).
    func reportOutputs(workURL: URL, cwd: URL) throws -> [(format: String, path: URL?)] {
        var outputs: [(format: String, path: URL?)] = []
        for name in reporter {
            guard Self.formats.contains(name) else { throw ValidationError("Unknown reporter: \(name) (known: \(Self.formats.joined(separator: ", ")))") }
            if name == "json", let jsonOutput {
                outputs.append((name, URL(fileURLWithPath: jsonOutput, relativeTo: cwd)))
            } else if let file = Self.defaultFileNames[name] {
                outputs.append((name, workURL.appendingPathComponent("report").appendingPathComponent(file)))
            } else {
                outputs.append((name, nil))
            }
        }
        for spec in report {
            guard let colon = spec.firstIndex(of: ":") else { throw ValidationError("--report takes <format>:<path>, got \(spec)") }
            let name = String(spec[..<colon])
            let path = String(spec[spec.index(after: colon)...])
            guard Self.formats.contains(name) else { throw ValidationError("Unknown report format: \(name) (known: \(Self.formats.joined(separator: ", ")))") }
            guard !path.isEmpty else { throw ValidationError("--report \(spec): the path is empty") }
            outputs.append((name, path == "-" ? nil : URL(fileURLWithPath: path, relativeTo: cwd)))
        }
        if jsonOutput != nil, !outputs.contains(where: { $0.format == "json" }) {
            outputs.append(("json", URL(fileURLWithPath: jsonOutput!, relativeTo: cwd)))
        }
        let onStdout = outputs.filter { $0.path == nil && $0.format != "text" }.map(\.format)
        if onStdout.count > 1 {
            throw ValidationError("Only one of \(onStdout.joined(separator: ", ")) can go to stdout; give the others a path with --report <format>:<path>.")
        }
        return outputs
    }

    func run() throws {
        // The progress file is written from the start: a run that stops early ends it with its exit code too
        if let progressFile = reports.progressFile {
            let url = URL(fileURLWithPath: progressFile, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
            do {
                try RunProgress.open(url, append: resume)
            } catch {
                throw ValidationError("--progress-file: cannot write \(url.path): \(error.localizedDescription)")
            }
        }
        do {
            try runAndReport()
            RunProgress.finish(exitCode: 0)
        } catch let exit as ExitCode {
            RunProgress.finish(exitCode: exit.rawValue)
            throw exit
        } catch let error as ValidationError {
            RunProgress.finish(exitCode: 64, message: error.message)
            throw error
        } catch {
            RunProgress.finish(exitCode: 1, message: "\(error)")
            throw error
        }
    }

    func runAndReport() throws {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let rootURL: URL
        if let root {
            rootURL = URL(fileURLWithPath: root, relativeTo: cwd).standardizedFileURL
        } else if let top = try? GitDiff.git(["rev-parse", "--show-toplevel"]).trimmingCharacters(in: .whitespacesAndNewlines), !top.isEmpty {
            rootURL = URL(fileURLWithPath: top).standardizedFileURL
        } else {
            rootURL = cwd.standardizedFileURL
        }
        guard FileManager.default.fileExists(atPath: rootURL.path) else { throw ValidationError("--root \(rootURL.path) does not exist") }
        let rootPath = rootURL.resolvingSymlinksInPath().path + "/"
        let canonicalRoot = Paths.canonical(rootURL) + "/"
        /// - Parameter mustExist: false for what `--prepare` may create in the work copy (a generated `.xcodeproj`).
        func relativeToRoot(_ path: String, mustExist: Bool = true) throws -> String {
            let url = URL(fileURLWithPath: path, relativeTo: cwd).standardizedFileURL
            if mustExist, !FileManager.default.fileExists(atPath: url.path) {
                throw ValidationError("\(path) does not exist (looked for \(url.path); paths are relative to the current directory)")
            }
            // Compared in canonical form: a path that does not exist yet is resolved through its existing parents, so that
            // a root under a symbolic link (/tmp) and a file in it are spelled the same way
            let absolute = Paths.canonical(url)
            if absolute + "/" == canonicalRoot { return "" }
            guard absolute.hasPrefix(canonicalRoot) else {
                throw ValidationError("\(path) is outside the root \(rootURL.path)\(FileManager.default.fileExists(atPath: url.path) ? "" : " (and does not exist)")")
            }
            return String(absolute.dropFirst(canonicalRoot.count))
        }

        let configURL = try configFile(given: config, root: rootURL, cwd: cwd)
        let mutatorConfig = try loadConfig(configURL)
        var initialWarnings = (mutatorConfig.loadWarnings + profileExpansion.warnings).map { RunWarning(kind: "config", message: $0) }
        if !profileExpansion.sources.isEmpty || !profileExpansion.overridden.isEmpty {
            let used = profileExpansion.sources.keys.sorted().map { "\($0)=\(profileExpansion.values[$0] ?? "") (\(profileExpansion.sources[$0] ?? ""))" }
            FileHandle.standardError.write(Data("\(ToolInfo.name): settings from \(URL(fileURLWithPath: profileExpansion.file ?? "").lastPathComponent): \(used.isEmpty ? "none" : used.joined(separator: ", "))\(profileExpansion.overridden.isEmpty ? "" : "; the command line replaced \(profileExpansion.overridden.joined(separator: ", "))")\n".utf8))
        }
        var excluded = RunReport.Excluded()

        var changed: [String: [ClosedRange<Int>]]?
        if let since {
            var map: [String: [ClosedRange<Int>]] = [:]
            let changes = try GitDiff.changes(since: since, root: rootURL)
            for (absolute, ranges) in changes.lines {
                let resolved = URL(fileURLWithPath: absolute).resolvingSymlinksInPath().path
                guard resolved.hasPrefix(rootPath) else { continue }
                let relative = String(resolved.dropFirst(rootPath.count))
                map[relative] = ranges
                if let why = changes.wholeFiles[absolute] {
                    let message = "--since \(since): \(relative): \(why)"
                    warn(message)
                    initialWarnings.append(RunWarning(kind: "sinceWholeFile", message: message, file: relative))
                }
                // A path in the diff that is not a file (and not a deleted one, which has no lines): the diff was not understood
                if !ranges.isEmpty, !FileManager.default.fileExists(atPath: resolved) {
                    let message = "--since \(since): the diff names \(relative), which does not exist under \(rootURL.path); its changes are not mutated. Please report the output of `git diff \(since) -- '*.swift' | head`"
                    warn(message)
                    initialWarnings.append(RunWarning(kind: "sinceUnknownPath", message: message, file: relative))
                }
            }
            changed = map
        }

        var targetFiles = try files.map { try relativeToRoot($0) }
        if targetFiles.isEmpty, !only.isEmpty {
            // The keys passed to --only start with the file path, so only those files are targeted (skipping analysis of all files)
            let fromKeys = Set(only.compactMap { $0.components(separatedBy: "::").first })
                .filter { FileManager.default.fileExists(atPath: rootURL.appendingPathComponent($0).path) }
            targetFiles = fromKeys.sorted()
        }
        // --package with a subdirectory and no --root: the default targets are the files of that package only. The root
        // (and with it the keys, the accepted file, the config file and the work directory) stays the git top level
        let packageDirectory: String? = try {
            guard root == nil, files.isEmpty, only.isEmpty, let package else { return nil }
            let relative = try relativeToRoot(package)
            return relative.isEmpty || relative == "." || relative.hasPrefix("/") ? nil : relative
        }()
        if targetFiles.isEmpty {
            // Default targets: the Swift files tracked by git (plus untracked ones that are not ignored), minus tests, generated code and the like.
            // Excluded files are not silently dropped but listed in the report. Those excluded although they are in the diff produce a warning
            var selection: FileSelector.Selection
            do {
                selection = try WorkCopyFiles.select(root: rootURL, patterns: (mutatorConfig.exclude ?? []) + exclude)
            } catch {
                // Without arguments the files are the ones that git knows: outside a repository there is no such list
                guard (try? GitDiff.git(["-C", rootURL.path, "rev-parse", "--is-inside-work-tree"])) == nil else { throw error }
                throw ValidationError("\(rootURL.path) is not inside a git repository, so there is no list of tracked files to choose from. Name the Swift files to mutate as arguments.")
            }
            if let packageDirectory { selection = selection.narrowed(to: packageDirectory) }
            targetFiles = selection.included
            let relevant = changed.map { map in selection.excluded.filter { map[$0.file] != nil } } ?? selection.excluded
            for file in relevant { excluded.counts[file.reason, default: 0] += 1 }
            // Test files are not listed one by one, except those outside a directory named like a test target: such a
            // file may be product code that was taken for a test, and must not drop out without its name being said
            let misplaced = Set(relevant.filter { $0.reason == "test-code" && FileSelector.conventionalTestDirectory(of: $0.file) == nil }.map(\.file))
            excluded.files = relevant.filter { $0.reason != "test-code" || misplaced.contains($0.file) }
            if changed == nil {
                for file in misplaced.sorted() {
                    let message = "\(file) is not mutated: it imports a test framework (test-code) although it is not in a test directory. If it is product code, add \"!\(file)\" to `exclude` in \(MutatorConfig.defaultName) or pass the file as an argument."
                    warn(message)
                    initialWarnings.append(RunWarning(kind: "excludedTestCode", message: message, file: file))
                }
            }
            if changed != nil {
                for file in excluded.files {
                    let message = "\(file.file) is changed but not mutated (\(file.reason)\(file.detail.map { ": \($0)" } ?? "")). To mutate it, add \"!\(file.file)\" to `exclude` in \(MutatorConfig.defaultName) or pass the file as an argument."
                    warn(message)
                    initialWarnings.append(RunWarning(kind: "excludedChangedFile", message: message, file: file.file))
                }
            }
        }
        if let changed {
            let candidates = targetFiles
            targetFiles = targetFiles.filter { changed[$0] != nil }
            // Files named on the command line that did not change are left out by --since: say so
            if !files.isEmpty, !targetFiles.isEmpty, targetFiles.count < candidates.count, let since {
                let unchanged = candidates.filter { changed[$0] == nil }
                warn("--since \(since): \(unchanged.count) of the \(candidates.count) files given did not change and are not mutated (\(unchanged.prefix(5).joined(separator: ", "))\(unchanged.count > 5 ? ", …" : "")). Without --since, the files given are mutated as a whole.")
            }
            // "0 mutants" must not look like "nothing to check" when Swift files did change
            if targetFiles.isEmpty, let since {
                let existing = changed.keys.filter { FileManager.default.fileExists(atPath: rootURL.appendingPathComponent($0).path) }
                    .filter { file in packageDirectory.map { file.hasPrefix($0 + "/") } ?? true }.sorted()
                if existing.isEmpty {
                    warn("--since \(since): no Swift file under \(packageDirectory.map { rootURL.appendingPathComponent($0).path } ?? rootURL.path) has changed; there is nothing to mutate.")
                } else {
                    let message = "--since \(since): \(existing.count) changed Swift file\(existing.count == 1 ? "" : "s") under the root (\(existing.prefix(5).joined(separator: ", "))\(existing.count > 5 ? ", …" : "")), and none of them is mutated: " + (files.isEmpty
                        ? "all are excluded (tests, generated code, `exclude`: see `files not mutated` in the report). To mutate one, pass it as an argument."
                        : "none of them is among the \(candidates.count) files given as arguments (--since narrows the files given to those that changed).")
                    warn(message)
                    initialWarnings.append(RunWarning(kind: "sinceNothingMutated", message: message))
                }
            }
        }

        // One spelling of the path whether or not the directory exists yet: `standardizedFileURL` turns
        // `/private/tmp/x` into `/tmp/x` only when `x` exists, so the first run and a `--resume` after it would see
        // two paths, and the paths are part of what `--resume` compares
        let workURL = workDir.map { URL(fileURLWithPath: Paths.canonical(URL(fileURLWithPath: $0, relativeTo: cwd))) }
            ?? WorkDirectoryInfo.defaultDirectory(forRoot: rootURL)
        let outputs = try reportOutputs(workURL: workURL, cwd: cwd)
        var copyRoot: URL?
        if copyScope == .gitRoot,
           let top = try? GitDiff.git(["-C", rootURL.path, "rev-parse", "--show-toplevel"]).trimmingCharacters(in: .whitespacesAndNewlines), !top.isEmpty {
            copyRoot = URL(fileURLWithPath: top).standardizedFileURL
        }
        let layout = RunLayout(root: rootURL, copyRoot: copyRoot, workDirectory: workURL)
        var container: [String] = []
        var workingDirectory: String?
        if let project {
            container = ["-project", layout.rootInCopy.appendingPathComponent(try relativeToRoot(project, mustExist: false)).path]
        } else if let workspace {
            container = ["-workspace", layout.rootInCopy.appendingPathComponent(try relativeToRoot(workspace, mustExist: false)).path]
        } else if let package {
            let relative = try relativeToRoot(package)
            workingDirectory = relative.isEmpty ? layout.rootInCopy.path : layout.rootInCopy.appendingPathComponent(relative).path
        }

        let xcode = XcodeOptions(
            container: container, scheme: scheme, destination: destination[0], testPlan: testPlan,
            extraBuildArguments: buildArg,
            extraTestArguments: testArg + onlyTestConfiguration.flatMap { ["-only-test-configuration", $0] },
            onlyTesting: onlyTesting, skipTesting: skipTesting,
            buildSettings: keepWarningsAsErrors ? [] : ["SWIFT_TREAT_WARNINGS_AS_ERRORS=NO", "GCC_TREAT_WARNINGS_AS_ERRORS=NO"],
            workingDirectory: workingDirectory)
        var config = RunConfiguration(
            root: rootURL, files: targetFiles, changedLines: changed, onlyKeys: only, xcode: xcode,
            prepareCommand: prepare, workDirectory: workURL,
            timeoutFactor: timeoutFactor, timeoutConstant: timeoutConstant, maxRebuilds: maxRebuilds,
            keepResultBundles: keepResults,
            generatorOptions: try Self.usage { try mutatorConfig.generatorOptions(extraArid: arid, extraDisabled: disableOperator, maxSwitches: maxSwitchesPerExpression, extraEnabled: enableOperator) })

        // Branches of `#if os(…)` that are not compiled for the destination hold no code that a test of this run can reach
        config.generatorOptions.targetPlatform = SimulatorCheck.platform(forDestination: destination[0])
        OperatorDeclarationSources.apply(to: &config.generatorOptions, root: rootURL,
                                         extraFiles: targetFiles.map { rootURL.appendingPathComponent($0).path })
        config.selectTestsAutomatically = selectTests == .auto
        config.selectTestsByReach = selectTests.narrowsByReach
        config.impactMap = reports.impactMap.map { URL(fileURLWithPath: $0, relativeTo: cwd).standardizedFileURL }
        config.writeImpactMap = reports.writeImpactMap.map { URL(fileURLWithPath: $0, relativeTo: cwd).standardizedFileURL }
        config.maxBisectBuilds = maxBisectBuilds
        config.packageCache = packageCache.map { URL(fileURLWithPath: $0, relativeTo: cwd).standardizedFileURL }
        let acceptedURL = accepted.map { URL(fileURLWithPath: $0, relativeTo: cwd) } ?? rootURL.appendingPathComponent(AcceptedFile.defaultName)
        config.accepted = try AcceptedFile.load(acceptedURL)
        config.copyRoot = layout.copyRoot
        config.resume = resume
        if !profileExpansion.sources.isEmpty || !profileExpansion.overridden.isEmpty {
            config.settings = RunReport.Settings(file: profileExpansion.file, profile: profileExpansion.profile,
                                                 fromFile: Dictionary(uniqueKeysWithValues: profileExpansion.sources.map { key, source in
                                                     (key, RunReport.Settings.Setting(value: profileExpansion.values[key] ?? "", source: source))
                                                 }),
                                                 overriddenByCommandLine: profileExpansion.overridden)
        }
        config.sharedProcess = speed.sharedProcess && !speed.sharedProcessAuto
        config.sharedProcessAuto = speed.sharedProcessAuto
        config.trustSharedSurvivors = trustSharedSurvivors
        config.directLaunch = !noDirectLaunch
        config.narrowGate = !speed.noNarrowGate
        config.stopAtFirstFailure = !speed.noStopAtFirstFailure
        config.reuse = reuse
        config.confirmKills = confirmKills
        config.recheckSurvivors = selectTests.narrowsByReach && (recheckSurvivors ?? true)
        config.filesWereGiven = !files.isEmpty
        config.maxMutants = maxMutants
        config.timeLimit = timeLimit.flatMap(TimeLimit.parse)
        config.timeLimitText = timeLimit
        config.additionalDestinations = Array(destination.dropFirst())
        config.workers = workers ?? destination.count
        config.initialWarnings = initialWarnings
        config.excluded = excluded
        config.fingerprintIgnoredPaths = Set(outputs.compactMap { $0.path }.flatMap { [$0.standardizedFileURL.path, Paths.canonical($0)] })
        config.fingerprintParts = ["since=\(since ?? "")", "files=\(targetFiles.joined(separator: ","))", "maxRebuilds=\(maxRebuilds)"]

        var gate = Gate(failUnder: failUnder, failOnSurvived: failOnSurvived)
        var earlierCommit: String?
        if let baselineReport {
            let url = URL(fileURLWithPath: baselineReport, relativeTo: cwd)
            guard let data = FileManager.default.contents(atPath: url.path) else { throw ValidationError("--baseline-report: cannot read \(url.path)") }
            do {
                let earlier = try Gate.earlierReport(data)
                // Mutants whose state the earlier report does not know (not run because that run was interrupted, or
                // without a verdict) are not new gaps
                gate.earlierUndetected = earlier.undetected.union(earlier.unknown)
                gate.earlierFiles = earlier.files
                earlierCommit = earlier.commit
                if !earlier.unknown.isEmpty {
                    warn("--baseline-report \(url.path): \(earlier.interrupted ? "that run was interrupted; " : "")the report does not know the state of \(earlier.unknown.count) mutants (not run, left out of a sample, RunnerError or NotActivated). They are not counted as new undetected mutants; a complete earlier report gives a stricter gate.")
                }
            } catch {
                throw ValidationError("--baseline-report \(url.path): \(error)")
            }
        }

        if reports.stopWhenGateDecided { config.stopWhenGateDecided = gate }
        InterruptHandler.install()
        if !noCaffeinate { SleepPrevention.start() }
        let runReport: RunReport
        do {
            runReport = try RunSession(config: config).run()
        } catch RunError.interrupted {
            if InterruptState.timeLimitReached {
                // Nothing to report: the time was up during the build or the baseline
                FileHandle.standardError.write(Data("\(ToolInfo.name): the time limit (--time-limit \(timeLimit ?? "")) was reached before the first mutant was run; there is no report. The limit has to leave room for the build and the two runs of the tests without mutants.\n".utf8))
                throw ExitCode(ExitCodes.infrastructure)
            }
            FileHandle.standardError.write(Data("\(ToolInfo.name): \(RunError.interrupted)\n".utf8))
            throw ExitCode(ExitCodes.interrupted)
        } catch let error as RunError {
            FileHandle.standardError.write(Data("\(ToolInfo.name): stopped: \(error)\n".utf8))
            throw ExitCode(error.isBaselineFailure ? ExitCodes.baselineFailed : ExitCodes.infrastructure)
        }

        // Reports (several formats can be output at once)
        let stdoutTaken = outputs.contains { $0.path == nil && $0.format != "text" }
        var written: [String] = []
        for output in outputs where output.format != "text" {
            let data: Data
            switch output.format {
            case "json": data = try JSONEncoder.pretty.encode(JSONReport(report: runReport))
            // Without indentation: the reader is a program or a model, and the indentation was a quarter of the size
            case "agent": data = try JSONEncoder.compact.encode(AgentReport(report: runReport))
            case "stryker": data = try StrykerReport(report: runReport).json()
            case "html": data = Data(try HTMLReport.render(runReport).utf8)
            case "markdown": data = Data(MarkdownReport.render(runReport).utf8)
            case "github": data = Data(GitHubReport.render(runReport, workspace: ProcessInfo.processInfo.environment["GITHUB_WORKSPACE"]).utf8)
            default: data = Data(XcodeReport.render(runReport).utf8)
            }
            if let path = output.path {
                try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
                if output.format == "markdown", FileManager.default.fileExists(atPath: path.path), ProcessInfo.processInfo.environment["GITHUB_STEP_SUMMARY"] == path.path {
                    // The GitHub job summary is appended to the content from earlier steps
                    let handle = try FileHandle(forWritingTo: path)
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                    try handle.close()
                } else {
                    try data.write(to: path)
                }
                written.append("\(output.format) report: \(path.path)")
            } else if !data.isEmpty {
                print(String(decoding: data, as: UTF8.self))
            }
        }
        for output in outputs where output.format == "text" {
            let text = TextReport.render(runReport) + (written.isEmpty ? "" : "\n\n" + written.joined(separator: "\n"))
            if let path = output.path {
                try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data((text + "\n").utf8).write(to: path)
            } else if stdoutTaken {
                FileHandle.standardError.write(Data((text + "\n").utf8))
            } else {
                print(text)
            }
        }
        if !outputs.contains(where: { $0.format == "text" }) {
            for line in written { FileHandle.standardError.write(Data("\(ToolInfo.name): \(line)\n".utf8)) }
        }

        // Exit code
        // A run that --time-limit cut short ends like a run that finished: the limit is a budget, not a failure
        // A run cut short because the gate's result was decided ends with that result, like a run that finished
        if runReport.interrupted, runReport.timeLimitReached != true, runReport.gateDecidedEarly != true { throw ExitCode(ExitCodes.interrupted) }
        // Files with undetected mutants that the earlier report did not examine. Two cases that must not be mixed up:
        // the file existed then and that run was limited to other files (not known to the baseline, not new), or it
        // did not exist then (new code: its gaps are new gaps). Which one is asked of git, at the commit of the
        // earlier report; whatever cannot be shown to have existed then counts as new.
        let outsideFiles = gate.filesOutsideEarlier(runReport)
        if !outsideFiles.isEmpty {
            var existed: Set<String> = []
            // Is the commit of the earlier report in this clone at all? In a shallow clone it is not, and "the file did
            // not exist at that commit" cannot be said. The gate then cannot be confirmed (exit code 7), which is not
            // the same as a new gap (exit code 5).
            let commitKnown = earlierCommit.map { (try? GitDiff.git(["-C", rootURL.path, "cat-file", "-e", "\($0)^{commit}"])) != nil }
            if let earlierCommit, commitKnown == true {
                for file in outsideFiles where (try? GitDiff.git(["-C", rootURL.path, "cat-file", "-e", "\(earlierCommit):./\(file)"])) != nil { existed.insert(file) }
            }
            gate.filesLeftOutThen = existed
            if let earlierCommit, commitKnown == false {
                gate.undeterminedFiles = Set(outsideFiles)
                gate.undeterminedReason = "the commit of the earlier report (\(earlierCommit.prefix(10))) is not in this clone, so it cannot be told whether \(outsideFiles.count) file\(outsideFiles.count == 1 ? "" : "s") with undetected mutants \(outsideFiles.count == 1 ? "is" : "are") new or were left out of the earlier run (\(outsideFiles.prefix(3).joined(separator: ", "))\(outsideFiles.count > 3 ? ", …" : "")). In a shallow clone, fetch the history (`git fetch --unshallow`; with actions/checkout: `fetch-depth: 0`)"
                warn("--baseline-report: " + (gate.undeterminedReason ?? ""))
            }
            let new = commitKnown == false ? [] : outsideFiles.filter { !existed.contains($0) }
            if !new.isEmpty {
                warn("--baseline-report: \(new.count) file\(new.count == 1 ? "" : "s") with undetected mutants \(new.count == 1 ? "is" : "are") not in the earlier report and \(earlierCommit == nil ? "the report does not name its commit" : "did not exist at its commit (\(earlierCommit!.prefix(10)))") (\(new.prefix(3).joined(separator: ", "))\(new.count > 3 ? ", …" : "")). Their undetected mutants count as new.")
            }
        }
        let outside = gate.outsideEarlierFiles(runReport)
        if !outside.isEmpty {
            let files = Array(Set(outside.map(\.mutant.file))).sorted()
            warn("--baseline-report: \(outside.count) undetected mutants are in \(files.count) file\(files.count == 1 ? "" : "s") that existed when the earlier report was made and that it did not examine (\(files.prefix(3).joined(separator: ", "))\(files.count > 3 ? ", …" : "")). They are not counted as new undetected mutants; include the files in the run that makes the baseline.")
        }
        let failures = gate.evaluate(runReport)
        for failure in failures {
            FileHandle.standardError.write(Data("\(ToolInfo.name): \(gate.isRequested ? "gate failed: " : "")\(failure.message)\n".utf8))
        }
        if let first = failures.first { throw ExitCode(first.exitCode) }
    }
}

enum Paths {
    /// The path with symbolic links resolved, also when its last components do not exist yet: the deepest existing
    /// directory is resolved (`realpath`) and the rest appended.
    static func canonical(_ url: URL) -> String { CanonicalPath.of(url) }
}

enum CopyScope: String, ExpressibleByArgument {
    case gitRoot = "git-root"
    case root
}

enum WorkCopyFiles {
    /// Selects the Swift files tracked by git (plus untracked ones that are not ignored) using the default rules and the config's `exclude` (`FileSelector`).
    static func select(root: URL, patterns: [String]) throws -> FileSelector.Selection {
        let listing = try GitDiff.git(["-C", root.path, "ls-files", "-z", "-co", "--exclude-standard", "--", "*.swift"])
        let paths = listing.split(separator: "\0").map(String.init)
        return FileSelector.select(paths: paths, patterns: patterns) { path in
            try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        }
    }
}

extension KillConfirmation: ExpressibleByArgument {}

enum TestSelectionMode: String, ExpressibleByArgument {
    case auto, reach, impact, none

    /// Mutants are narrowed to the suites that reached them (`impact` chooses the selection first, then narrows the same way).
    var narrowsByReach: Bool { self == .reach || self == .impact }
}

/// `init`: tries the project and writes the run options of the config file (`ProjectSetup`).
struct InitCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "init",
        abstract: "Try the project and write the run options of \(MutatorConfig.defaultName): a `run` object and the profiles pr and nightly.",
        discussion: """
        Finds the workspace, project or package and its scheme, builds for testing, leaves out UI test targets and extra \
        test-plan configurations, and runs a sample of mutants twice: in the default mode and with the faster modes \
        (--select-tests reach --shared-process, and --confirm-kills restore for app-hosted tests on a simulator). A faster \
        mode is chosen only when it gave the same verdicts and was faster per mutant. Options that make verdicts weaker \
        and gates are never chosen. The reasons are printed and kept in the file as comments. The sample is taken from the \
        files given, --path, or the current directory below the root. Trials on a simulator use a simulator of their \
        own, created like the booted one with its privacy settings for the app, and deleted at the end.
        """
    )

    @Option(help: "The repository (default: the top level of the git repository of the current directory).")
    var root: String?
    @Option(help: "Xcode workspace (default: the one at the top of the repository).")
    var workspace: String?
    @Option(help: "Xcode project.")
    var project: String?
    @Option(help: "Swift package directory.")
    var package: String?
    @Option(help: "Scheme (default: the only one, or with --yes the one named after the project).")
    var scheme: String?
    @Option(help: "Destination (default: macOS for a package, the booted iOS simulator for a project).")
    var destination: String?
    @Option(help: "Config file to write (default: <root>/\(MutatorConfig.defaultName)). A path ending in .json is written as JSON, with the reasons under `_why`.")
    var config: String?
    @Argument(help: "Swift files (relative to the current directory) that the trials mutate: the sample is taken from them. Default: the files below --path, or below the current directory when it is inside the repository, else the whole repository.")
    var files: [String] = []
    @Option(help: "A directory whose Swift files the trials mutate (tests, generated code and the exclude patterns left out).")
    var path: String?
    @Option(parsing: .singleValue, help: "Extra argument for the build (repeatable; write it as --build-arg=-quiet). Used for the trials and written into `run`.")
    var buildArg: [String] = []
    @Option(help: "A SourcePackages directory to copy before the build (as with run). Used for the trials and written into `run`.")
    var packageCache: String?
    @Option(help: "Work directory for the trials, written into `run` for later runs. Default: the trials work in the temporary directory, and runs in their default work directory.")
    var workDir: String?
    @Option(help: "Mutants in each trial.")
    var sample: Int = 10
    @Flag(help: "Print the file instead of writing it.")
    var dryRun = false
    @Flag(help: "Do not stop where a choice is open (several schemes): take the default and say so. For CI and coding agents.")
    var yes = false
    @Flag(help: "Replace the run options of an existing config file (its other keys are kept). With \(ConfigFile.jsonName) of an earlier version at the root: write its settings into \(MutatorConfig.defaultName) and remove it.")
    var force = false

    func run() throws {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let rootURL: URL
        if let root {
            rootURL = URL(fileURLWithPath: root, relativeTo: cwd).standardizedFileURL
        } else if let top = try? GitDiff.git(["rev-parse", "--show-toplevel"]).trimmingCharacters(in: .whitespacesAndNewlines), !top.isEmpty {
            rootURL = URL(fileURLWithPath: top)
        } else {
            rootURL = cwd
        }
        // Where init writes, and the JSON file of an earlier version that it moves there
        let targets: (target: URL, legacy: URL?)
        do {
            targets = try ProjectSetup.targets(given: config.map { URL(fileURLWithPath: $0, relativeTo: cwd).standardizedFileURL }, root: rootURL)
        } catch let ambiguous as ConfigFile.Ambiguous {
            throw ValidationError(ambiguous.description)
        }
        let file = targets.target
        let executable = Bundle.main.executableURL?.path ?? CommandLine.arguments[0]
        var options = ProjectSetup.Options(root: rootURL, configFile: file, executable: executable, cwd: cwd)
        options.files = files
        options.legacyConfig = targets.legacy
        options.path = path
        options.buildArguments = buildArg
        options.packageCache = packageCache
        options.workDir = workDir
        options.workspace = workspace
        options.project = project
        options.package = package
        options.scheme = scheme
        options.destination = destination
        options.dryRun = dryRun
        options.yes = yes
        options.force = force
        options.sample = max(sample, 1)
        InterruptHandler.install()
        do {
            let code = try ProjectSetup.perform(options) { FileHandle.standardError.write(Data("\(ToolInfo.name): \($0)\n".utf8)) }
            if code != 0 { throw ExitCode(code) }
        } catch let failure as ProjectSetup.Failure {
            FileHandle.standardError.write(Data("\(ToolInfo.name): init: \(failure.description)\n".utf8))
            throw ExitCode(ExitCodes.infrastructure)
        }
    }
}

struct Accept: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Record a mutant that no test can detect.",
        discussion: """
        For an equivalent mutant: no input can tell the mutated code from the original. \
        The keys go into \(AcceptedFile.defaultName), which is meant to be committed and reviewed like code. Later \
        runs report these mutants as Accepted: not counted, not listed as gaps. A run warns when an accepted mutant \
        is detected again or no longer exists. Accept only keys taken from the gaps of a run.

        Example:
          \(ToolInfo.name) accept '<key from the report>' \\
            --reason "both branches return the same value when the sides are equal"
        """)

    @Argument(help: "Stable keys of the mutants (from the report).")
    var keys: [String]

    @Option(help: "Why no input can tell the mutated code from the original.")
    var reason: String

    @Option(help: "Accepted mutants file (default: <root>/\(AcceptedFile.defaultName), the same file run reads).")
    var file: String?

    @Option(help: "Root directory, as passed to run --root (default: the git top-level directory of the current directory).")
    var root: String?

    @Option(help: "JSON report of the run the keys came from; used to record the location of each mutant.")
    var report: String?

    func run() throws {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let url: URL
        if let file {
            url = URL(fileURLWithPath: file, relativeTo: cwd)
        } else if let root {
            url = URL(fileURLWithPath: root, relativeTo: cwd).standardizedFileURL.appendingPathComponent(AcceptedFile.defaultName)
        } else {
            let top = (try? GitDiff.git(["rev-parse", "--show-toplevel"]).trimmingCharacters(in: .whitespacesAndNewlines)) ?? cwd.path
            url = URL(fileURLWithPath: top).appendingPathComponent(AcceptedFile.defaultName)
        }
        var locations: [String: String] = [:]
        var statuses: [String: String] = [:]
        var reportRead = false
        if let report {
            let reportURL = URL(fileURLWithPath: report, relativeTo: cwd)
            guard let data = FileManager.default.contents(atPath: reportURL.path),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let results = json["results"] as? [Any] else {
                throw ValidationError("--report \(reportURL.path): cannot be read as a \(ToolInfo.name) JSON report")
            }
            if let scheme = json["keyVersion"] as? Int, scheme != MutantKeyScheme.version {
                throw ValidationError("--report \(reportURL.path): the report was written with another scheme of stable keys (by another version of the tool); its keys do not name mutants of this version. Run again and accept from the new report")
            }
            reportRead = true
            for case let result as [String: Any] in results {
                guard let m = result["mutant"] as? [String: Any], let key = m["key"] as? String,
                      let file = m["file"] as? String, let start = m["start"] as? [String: Any] else { continue }
                let change = (m["operator"] as? String) == "side-effect-removal"
                    ? "remove `\(m["original"] as? String ?? "")`"
                    : "\(m["original"] as? String ?? "") -> \(m["replacement"] as? String ?? "")"
                locations[key] = "\(file):\(start["line"] as? Int ?? 0):\(start["column"] as? Int ?? 0) \(change)"
                statuses[key] = result["status"] as? String
            }
        }
        var accepted = try AcceptedFile.load(url)
        let formatter = ISO8601DateFormatter()
        var added = 0
        var updated = 0
        for key in keys {
            // With the report at hand, a key that the report does not hold, or holds as detected, is most likely a mistake
            if reportRead {
                if let status = statuses[key] {
                    if status != MutantStatus.survived.rawValue, status != MutantStatus.notReached.rawValue, status != MutantStatus.accepted.rawValue {
                        warn("\(key) is \(status) in the report, not an undetected mutant; it is recorded all the same, and the next run will warn if it is detected.")
                    }
                } else {
                    warn("\(key) is not in the report; it is recorded all the same, and the next run will warn if no mutant has this key.")
                }
            }
            if accepted.accepted.contains(where: { $0.key == key }) { updated += 1 } else { added += 1 }
            accepted.accepted.removeAll { $0.key == key }
            accepted.accepted.append(AcceptedFile.Entry(key: key, reason: reason, location: locations[key], acceptedAt: formatter.string(from: Date())))
        }
        accepted.accepted.sort { $0.key < $1.key }
        try accepted.save(url)
        func count(_ n: Int) -> String { "\(n) mutant\(n == 1 ? "" : "s")" }
        print("accepted \(count(added))\(updated > 0 ? " and updated the reason of \(count(updated))" : "") in \(url.path)")
    }
}

struct Clean: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Remove the work directory of `run`.",
        discussion: """
        The work directory holds the copy of the sources, the build, logs and reports. \
        Without options: the work directory of the current repository (under ~/Library/Caches/\(ToolNaming.cacheDirectoryName)). \
        Each repository has its own, and the build inside can take gigabytes; deleting a repository or a worktree does \
        not delete it. --orphans removes the directories whose repository no longer exists, --all every one of them. \
        Simulators that a run with --workers left behind are removed as well.

        Examples:
          \(ToolInfo.name) clean
          \(ToolInfo.name) clean --orphans
        """)

    @Option(help: "Root directory, as passed to run --root (default: the git top-level directory of the current directory).")
    var root: String?

    @Option(help: "Work directory passed to run --work-dir. Only removed if \(ToolInfo.name) created it.")
    var workDir: String?

    @Flag(help: "Every directory under ~/Library/Caches/\(ToolNaming.cacheDirectoryName), whichever checkout or session it belongs to (on a shared machine, look at --all --dry-run first; directories that a run is using are skipped).")
    var all = false

    @Flag(help: "Only directories under ~/Library/Caches/\(ToolNaming.cacheDirectoryName) whose root no longer exists (removed worktrees).")
    var orphans = false

    @Flag(help: "Show what would be removed and its size, without removing.")
    var dryRun = false

    func validate() throws {
        if [all, orphans, workDir != nil, root != nil].filter({ $0 }).count > 1 {
            throw ValidationError("Specify at most one of --all, --orphans, --work-dir and --root.")
        }
    }

    func run() throws {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        // Worker simulators (run --workers) whose run no longer exists. Always, whichever directories are asked for
        if dryRun {
            for name in SimulatorWorkers.orphanNames() { print("would remove the worker simulator \(name) (its run no longer exists)") }
        } else {
            for name in SimulatorWorkers.removeOrphans() { print("removed the worker simulator \(name) (its run no longer exists)") }
        }
        var entries: [WorkDirectoryInfo.Entry] = []
        if all || orphans {
            entries = WorkDirectoryInfo.listDefault()
            if orphans { entries = entries.filter(\.isOrphan) }
        } else if let workDir {
            let url = URL(fileURLWithPath: Paths.canonical(URL(fileURLWithPath: workDir, relativeTo: cwd)))
            guard FileManager.default.fileExists(atPath: url.path) else {
                print("nothing to remove: \(url.path) does not exist")
                return
            }
            guard WorkDirectoryInfo.isRemovable(url) else {
                throw ValidationError("\(url.path) was not created by \(ToolInfo.name) (no \(WorkDirectoryInfo.fileName) inside); not removing it.")
            }
            entries = [WorkDirectoryInfo.entry(url)]
        } else {
            let rootURL: URL
            if let root {
                rootURL = URL(fileURLWithPath: root, relativeTo: cwd).standardizedFileURL
            } else if let top = try? GitDiff.git(["rev-parse", "--show-toplevel"]).trimmingCharacters(in: .whitespacesAndNewlines), !top.isEmpty {
                rootURL = URL(fileURLWithPath: top).standardizedFileURL
            } else {
                rootURL = cwd.standardizedFileURL
            }
            // Both the current name (with .noindex) and the name used by earlier versions
            let current = WorkDirectoryInfo.defaultDirectory(forRoot: rootURL)
            let legacy = current.deletingPathExtension()
            entries = [current, legacy].filter { FileManager.default.fileExists(atPath: $0.path) }.map(WorkDirectoryInfo.entry)
            if entries.isEmpty {
                print("nothing to remove: no work directory for \(rootURL.path) (\(current.path))")
                return
            }
        }
        if entries.isEmpty {
            print("nothing to remove")
            return
        }
        var total: Int64 = 0
        var skippedBusy = 0
        for entry in entries {
            total += entry.sizeBytes
            let root = entry.info.map { "root \($0.root)\(entry.isOrphan ? " (no longer exists)" : ""), last used \($0.lastUsedAt)" } ?? "root unknown (no marker file: a directory that holds several work directories, or one made by an earlier version)"
            print("\(dryRun ? "would remove" : "removing") \(entry.url.path)  \(WorkDirectoryInfo.formatSize(entry.sizeBytes))  \(root)")
            if WorkDirectoryLock.isHeld(entry.url) {
                print("  skipped: a \(ToolInfo.name) run is using it")
                skippedBusy += 1
                total -= entry.sizeBytes
                continue
            }
            if !dryRun {
                try FileManager.default.removeItem(at: entry.url)
                PackageLockFiles.remove(derivedData: entry.url.appendingPathComponent("DerivedData"))
            }
        }
        let removed = entries.count - skippedBusy
        print("\(dryRun ? "would free" : "freed") about \(WorkDirectoryInfo.formatSize(total)) in \(removed) director\(removed == 1 ? "y" : "ies")")
        if skippedBusy > 0, !all, !orphans { throw ExitCode(ExitCodes.infrastructure) }
    }
}

enum OperatorDeclarationSources {
    /// The Swift files tracked by git under root (plus files passed on the command line), as text.
    static func sources(root: URL, extraFiles: [String]) -> [String] {
        var paths = Set(extraFiles.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        if let listing = try? GitDiff.git(["-C", root.path, "ls-files", "-z", "-co", "--exclude-standard", "--", "*.swift"]) {
            for line in listing.split(separator: "\0") where !line.isEmpty {
                paths.insert(root.appendingPathComponent(String(line)).standardizedFileURL.path)
            }
        }
        return paths.sorted().compactMap { try? String(contentsOfFile: $0, encoding: .utf8) }
    }

    /// Collects what the generator needs from the other files of the project: operator declarations, the names of
    /// functions that do not return, and the names of result builder types.
    static func apply(to options: inout GeneratorOptions, root: URL, extraFiles: [String]) {
        let sources = sources(root: root, extraFiles: extraFiles)
        options.extraOperatorDeclarations = OperatorDeclarations.extract(from: sources)
        ProjectDeclarations.scan(sources: sources).apply(to: &options)
    }
}
