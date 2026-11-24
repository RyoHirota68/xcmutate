import Foundation
@testable import MutatorCore
@testable import MutatorRunner
import Testing

/// The built executable, run on small directories (no xcodebuild, no simulator): what `--since` selects under
/// git settings that change the output of git, and the exit
/// statuses of runs that end before the build.
@Suite(.serialized) struct CommandLineTests {
    /// The executable that the same build produced, next to the test bundle.
    static let executable: String? = {
        let candidates = Bundle.allBundles.map { $0.bundleURL.deletingLastPathComponent().appendingPathComponent("xcmutate").path }
            + [repositoryRoot.appendingPathComponent(".build/debug/xcmutate").path]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    static var available: Bool { executable != nil && FileManager.default.isExecutableFile(atPath: "/usr/bin/git") }

    private func run(_ arguments: [String], in directory: URL) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try #require(Self.executable))
        process.arguments = arguments
        process.currentDirectoryURL = directory
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    @discardableResult
    private func git(_ arguments: [String], in directory: URL) throws -> String {
        let result = try #require(runProcess("/usr/bin/git", ["-C", directory.path, "-c", "user.email=test@example.com", "-c", "user.name=Test",
                                                               "-c", "commit.gpgsign=false"] + arguments))
        try #require(result.status == 0, "git \(arguments.joined(separator: " ")): \(result.output)")
        return result.output
    }

    /// A repository with three committed Swift files; the caller changes them.
    private func withRepository(_ body: (URL) throws -> Void) throws {
        try withTemporaryDirectory("xcmutate-cli") { directory in
            try git(["init", "-q", "."], in: directory)
            for path in ["Sources/A.swift", "Sources/画面/B.swift", "Sources/C.swift"] {
                let url = directory.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try "func keep(_ a: Int) -> Bool {\n    return a == 0\n}\n".write(to: url, atomically: true, encoding: .utf8)
            }
            try git(["add", "-A"], in: directory)
            try git(["commit", "-q", "-m", "init"], in: directory)
            try body(directory)
        }
    }

    private func change(_ path: String, in directory: URL) throws {
        let url = directory.appendingPathComponent(path)
        let text = try String(contentsOf: url, encoding: .utf8)
        try (text + "func added(_ a: Int) -> Bool {\n    return a > 1\n}\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// The files that `list --since HEAD` finds mutants in.
    private func mutatedFiles(_ directory: URL, files: [String]) throws -> Set<String> {
        let result = try run(["list", "--since", "HEAD", "--root", "."] + files, in: directory)
        try #require(result.status == 0, "\(result.output)")
        return Set(result.output.split(separator: "\n").compactMap { line -> String? in
            guard line.contains(": ["), let colon = line.range(of: ".swift:") else { return nil }
            return String(line[..<colon.lowerBound]) + ".swift"
        })
    }

    static let all = ["Sources/A.swift", "Sources/画面/B.swift", "Sources/C.swift"]

    @Test(.enabled(if: available)) func sinceFindsChangesInPathsThatGitQuotes() throws {
        try withRepository { directory in
            try change("Sources/A.swift", in: directory)
            try change("Sources/画面/B.swift", in: directory)
            // An untracked file in a directory with a non-ASCII name
            try "func fresh(_ a: Int) -> Bool {\n    return a > 1\n}\n".write(to: directory.appendingPathComponent("Sources/画面/新規.swift"), atomically: true, encoding: .utf8)
            let files = Self.all + ["Sources/画面/新規.swift"]
            #expect(try mutatedFiles(directory, files: files) == ["Sources/A.swift", "Sources/画面/B.swift", "Sources/画面/新規.swift"])
            // The same with the setting that prints such paths as they are
            try git(["config", "core.quotePath", "false"], in: directory)
            #expect(try mutatedFiles(directory, files: files) == ["Sources/A.swift", "Sources/画面/B.swift", "Sources/画面/新規.swift"])
        }
    }

    @Test(.enabled(if: available)) func sinceDoesNotDependOnThePrefixSettingsOfGit() throws {
        try withRepository { directory in
            try change("Sources/A.swift", in: directory)
            for setting in ["diff.mnemonicPrefix", "diff.noprefix"] {
                try git(["config", setting, "true"], in: directory)
                #expect(try mutatedFiles(directory, files: Self.all) == ["Sources/A.swift"], "\(setting)")
                try git(["config", "--unset", setting], in: directory)
            }
        }
    }

    @Test(.enabled(if: available)) func sinceSeesChangesThatGitDiffHides() throws {
        try withRepository { directory in
            // assume-unchanged: `git diff` shows nothing for the file, the work copy has the changed text
            try change("Sources/A.swift", in: directory)
            try git(["update-index", "--assume-unchanged", "Sources/A.swift"], in: directory)
            #expect(try git(["diff", "HEAD", "--stat"], in: directory).isEmpty)
            #expect(try mutatedFiles(directory, files: Self.all) == ["Sources/A.swift"])
            try git(["update-index", "--no-assume-unchanged", "Sources/A.swift"], in: directory)
            // `*.swift -diff` in .gitattributes: git reports "Binary files differ" without lines
            try "*.swift -diff\n".write(to: directory.appendingPathComponent(".gitattributes"), atomically: true, encoding: .utf8)
            try change("Sources/C.swift", in: directory)
            #expect(try mutatedFiles(directory, files: Self.all) == ["Sources/A.swift", "Sources/C.swift"])
        }
    }

    /// Only the added lines are mutated (the diff is read, not just the file names).
    @Test(.enabled(if: available)) func sinceMutatesOnlyTheChangedLines() throws {
        try withRepository { directory in
            try change("Sources/A.swift", in: directory)
            let result = try run(["list", "--since", "HEAD", "--root", ".", "Sources/A.swift"], in: directory)
            let lines = result.output.split(separator: "\n").filter { $0.contains(": [") }
            #expect(!lines.isEmpty)
            #expect(lines.allSatisfy { $0.hasPrefix("Sources/A.swift:5:") }, "\(result.output)")
        }
    }

    private func runArguments(_ directory: URL, _ extra: [String]) -> [String] {
        ["run", "--root", ".", "--package", ".", "--scheme", "None", "--destination", "platform=macOS", "--no-caffeinate",
         "--work-dir", directory.appendingPathComponent(".build/work").path, "--reporter", "text"] + extra
    }

    /// A key that names nothing is not "0 mutants, success".
    @Test(.enabled(if: available)) func onlyWithKeysThatNameNothingIsAnError() throws {
        try withRepository { directory in
            let result = try run(runArguments(directory, ["--only", "Sources/A.swift::keep(_:)::equality-flip::0000000000000000", "--fail-on-survived"]), in: directory)
            #expect(result.status == 2, "\(result.output)")
            #expect(result.output.contains("none of the 1 keys given with --only names a mutant"))
        }
    }

    /// A file that the tool's parser rejects although the compiler accepts it: named, and no gate passes.
    @Test(.enabled(if: available)) func aFileThatCannotBeParsedIsNamedAndFailsTheGate() throws {
        try withRepository { directory in
            let source = "public func gate(_ x: Int) -> Bool {\n    return x > 10\n}\n#if compiler(>=99.0)\npublic func future() { this is syntax from a future compiler @@ }\n#endif\n"
            try source.write(to: directory.appendingPathComponent("Sources/Future.swift"), atomically: true, encoding: .utf8)
            let gated = try run(runArguments(directory, ["--fail-on-survived", "--fail-under", "100", "Sources/Future.swift"]), in: directory)
            #expect(gated.status == 7, "\(gated.output)")
            #expect(gated.output.contains("Sources/Future.swift was not mutated"))
            #expect(gated.output.contains("[skippedFile]"))
            #expect(gated.output.contains("the gate cannot be confirmed"))
            // Without a gate the run ends normally, and still says so
            let plain = try run(runArguments(directory, ["Sources/Future.swift"]), in: directory)
            #expect(plain.status == 0)
            #expect(plain.output.contains("Sources/Future.swift was not mutated"))
        }
    }

    /// A work directory that the tool did not make, through the command line.
    @Test(.enabled(if: available)) func anExistingDirectoryIsNotUsedAsWorkDirectory() throws {
        try withRepository { directory in
            let other = directory.appendingPathComponent(".build/documents")
            try FileManager.default.createDirectory(at: other.appendingPathComponent("src"), withIntermediateDirectories: true)
            try "keep me".write(to: other.appendingPathComponent("src/notes.txt"), atomically: true, encoding: .utf8)
            var arguments = runArguments(directory, ["Sources/A.swift"])
            arguments[arguments.firstIndex(of: "--work-dir")! + 1] = other.path
            let result = try run(arguments, in: directory)
            #expect(result.status == 2, "\(result.output)")
            #expect(result.output.contains("was not made by xcmutate"))
            #expect(try String(contentsOf: other.appendingPathComponent("src/notes.txt"), encoding: .utf8) == "keep me")
        }
    }

    /// A path that does not exist is said not to exist (and not to be "outside the root"), also under a symbolic link.
    @Test(.enabled(if: available)) func aPathThatDoesNotExistIsNamedAsSuch() throws {
        try withRepository { directory in
            let missing = try run(runArguments(directory, ["Sources/NoSuchFile.swift"]), in: directory)
            #expect(missing.status == 64, "\(missing.output)")
            #expect(missing.output.contains("Sources/NoSuchFile.swift does not exist"))
            // The same directory reached through a symbolic link: an existing file is still inside the root
            let link = directory.deletingLastPathComponent().appendingPathComponent("link-\(UUID().uuidString)")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory)
            defer { try? FileManager.default.removeItem(at: link) }
            let listed = try run(["list", "--root", ".", "Sources/A.swift"], in: link)
            #expect(listed.status == 0, "\(listed.output)")
            let viaLink = try run(runArguments(link, ["--only", "Sources/A.swift::nothing::boundary::0", "Sources/A.swift"]), in: link)
            #expect(viaLink.output.contains("none of the 1 keys"), "\(viaLink.output)")
            // A project that only --prepare creates need not exist yet
            var arguments = runArguments(directory, ["--only", "Sources/A.swift::nothing::boundary::0"])
            arguments.replaceSubrange(arguments.firstIndex(of: "--package")!...arguments.firstIndex(of: "--package")! + 1, with: ["--project", "Generated.xcodeproj"])
            let generated = try run(arguments, in: directory)
            #expect(generated.output.contains("none of the 1 keys"), "\(generated.output)")
        }
    }

    @Test(.enabled(if: available)) func mistakesInOptionsAreUsageErrors() throws {
        try withRepository { directory in
            let operatorName = try run(runArguments(directory, ["--disable-operator", "boundry", "Sources/A.swift"]), in: directory)
            #expect(operatorName.status == 64, "\(operatorName.output)")
            #expect(operatorName.output.contains("unknown operator boundry"))
            let noScheme = try run(["run", "--root", ".", "--project", "App.xcodeproj", "--destination", "platform=macOS"], in: directory)
            #expect(noScheme.status == 64)
            #expect(noScheme.output.contains("need --scheme"))
            // The recheck of survivors belongs to --select-tests reach: both spellings are refused without it
            for flag in ["--recheck-survivors", "--no-recheck-survivors"] {
                let result = try run(runArguments(directory, [flag, "Sources/A.swift"]), in: directory)
                #expect(result.status == 64, "\(result.output)")
                #expect(result.output.contains("\(flag) needs --select-tests reach"))
            }
        }
    }

    /// An earlier report with keys of another scheme is refused instead of failing the gate for every mutant.
    @Test(.enabled(if: available)) func aBaselineReportOfAnotherKeySchemeIsRefused() throws {
        try withRepository { directory in
            let old = directory.appendingPathComponent("old.json")
            try #"{"version": 1, "keyVersion": 1, "tool": {"name": "xcmutate", "version": "0.0.1"}, "results": []}"#.write(to: old, atomically: true, encoding: .utf8)
            let result = try run(runArguments(directory, ["--baseline-report", old.path, "Sources/A.swift"]), in: directory)
            #expect(result.status == 64, "\(result.output)")
            #expect(result.output.contains("stable keys of scheme 1"))
        }
    }
}

// MARK: The guide for coding agents

extension CommandLineTests {
    private static var guideURL: URL { repositoryRoot.appendingPathComponent("docs/agent-guide.md") }

    /// `agent-guide` prints docs/agent-guide.md byte for byte, from a string compiled into the executable
    /// (scripts/generate-agent-guide.py makes it): nothing on standard error, exit status 0, in any directory.
    @Test func theGuideForAgentsIsTheDocumentByteForByte() throws {
        let document = try Data(contentsOf: Self.guideURL)
        #expect(Data(AgentGuide.text.utf8) == document, "run scripts/generate-agent-guide.py")
        guard let executable = Self.executable else { return }
        try withTemporaryDirectory { directory in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = ["agent-guide"]
            process.currentDirectoryURL = directory
            let output = Pipe(), errors = Pipe()
            process.standardOutput = output
            process.standardError = errors
            try process.run()
            let printed = output.fileHandleForReading.readDataToEndOfFile()
            let complaints = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
            #expect(printed == document)
            #expect(complaints.isEmpty)
        }
    }

    /// `list --since <ref>` without file arguments takes the changed files among those that `run` would mutate,
    /// uncommitted changes included (the guide counts the mutants of a change this way).
    @Test(.enabled(if: available)) func listWithSinceNeedsNoFileArguments() throws {
        try withRepository { directory in
            try change("Sources/A.swift", in: directory)
            let result = try run(["list", "--since", "HEAD"], in: directory)
            #expect(result.status == 0, "\(result.output)")
            #expect(result.output.contains("Sources/A.swift:"))
            #expect(!result.output.contains("Sources/C.swift:"))
            #expect(result.output.hasSuffix(" ignored, 1 files\n"))
            // Without --since there is nothing to choose the files by
            let bare = try run(["list"], in: directory)
            #expect(bare.status == 64)
            #expect(bare.output.contains("give --since <ref>"))
            #expect(try run(["instrument", "--in-place"], in: directory).status == 64)
        }
    }

    /// Every `--option` and every subcommand that the guide names exists (read from the help of the executable), so
    /// that an agent following it does not meet "Unknown option".
    @Test(.enabled(if: available)) func theGuideNamesOnlyOptionsAndSubcommandsThatExist() throws {
        let guide = try String(contentsOf: Self.guideURL, encoding: .utf8)
        let here = FileManager.default.temporaryDirectory
        func words(_ text: String, _ pattern: String) -> Set<String> {
            let regex = try! NSRegularExpression(pattern: pattern)
            let range = NSRange(text.startIndex..., in: text)
            return Set(regex.matches(in: text, range: range).compactMap { Range($0.range(at: 1), in: text).map { String(text[$0]) } })
        }
        let top = try run(["--help"], in: here).output
        let subcommands = words(top, #"(?m)^  ([a-z][a-z-]+)  "#).subtracting(["help"])
        #expect(subcommands.isSuperset(of: ["run", "list", "accept", "clean", "instrument", "agent-guide"]))
        var options: Set<String> = []
        for subcommand in subcommands {
            options.formUnion(words(try run([subcommand, "--help"], in: here).output, #"(--[a-z][a-z-]*)"#))
        }
        let named = words(guide, #"(--[a-z][a-z-]*)"#)
        #expect(named.count > 20)
        let unknown = named.subtracting(options).sorted()
        #expect(unknown.isEmpty, "the guide names options that no subcommand has: \(unknown)")
        let used = words(guide, #"xcmutate ([a-z][a-z-]+)"#).subtracting(["makes", "is", "works", "learned"])
        let missing = used.filter { !subcommands.contains($0) }.sorted()
        #expect(missing.isEmpty, "the guide names subcommands that do not exist: \(missing)")
        #expect(used.isSuperset(of: ["run", "list", "accept", "clean", "agent-guide"]))
    }

    /// The warnings and the fields of the report for agents that the guide names are the ones the tool writes.
    @Test func theGuideNamesOnlyWarningsAndFieldsThatExist() throws {
        let guide = try String(contentsOf: Self.guideURL, encoding: .utf8)
        // The rows of the table of warnings: "| `kind`, `kind` | what it means |"
        let table = guide.components(separatedBy: "| Warning | What it means for you |").dropFirst().first?.components(separatedBy: "\n\n").first ?? ""
        var kinds: [String] = []
        for row in table.split(separator: "\n").dropFirst() {
            let cell = row.split(separator: "|", omittingEmptySubsequences: true).first.map(String.init) ?? ""
            kinds += cell.split(separator: "`").enumerated().filter { $0.offset % 2 == 1 }.map { String($0.element) }
        }
        #expect(kinds.count >= 13)
        var sources = ""
        let sourcesDirectory = repositoryRoot.appendingPathComponent("Sources")
        for case let file as URL in FileManager.default.enumerator(at: sourcesDirectory, includingPropertiesForKeys: nil)! where file.pathExtension == "swift" {
            sources += (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        }
        for kind in kinds {
            #expect(sources.contains("kind: \"\(kind)\""), "no warning of kind \(kind) is written by the tool")
        }
        // The fields, in a report with one gap
        var report = ConfigJournalAndReportTests.report([(.survived, "App/Cart.swift"), (.runnerError, "App/Cart.swift")])
        report.warnings = [RunWarning(kind: "sampled", message: "m")]
        let data = try JSONEncoder().encode(AgentReport(report: report))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for field in ["warnings", "unevaluatedCount", "interrupted", "pendingCount", "scopes", "obligations", "score", "counts"] {
            #expect(json[field] != nil, "the report for agents has no field \(field)")
            #expect(guide.contains("`\(field)`") || guide.contains("`\(field)[") || guide.contains("`\(field)["), "the guide does not name \(field)")
        }
        let scope = try #require((json["scopes"] as? [[String: Any]])?.first)
        for field in ["file", "startLine", "endLine", "source", "gaps"] { #expect(scope[field] != nil, "a scope has no field \(field)") }
        let gap = try #require((scope["gaps"] as? [[String: Any]])?.first)
        for field in ["key", "gap", "line", "column", "mutator", "original", "replacement"] { #expect(gap[field] != nil, "a gap has no field \(field)") }
        #expect(["notReached", "notDetected"].contains(gap["gap"] as? String ?? ""))
    }
}

// MARK: agent-guide --install

extension CommandLineTests {
    /// The skill compiled into the tool is the file of this repository, byte for byte.
    @Test func theInstalledSkillIsTheFileOfTheRepository() throws {
        let file = try Data(contentsOf: repositoryRoot.appendingPathComponent(".claude/skills/mutation-test-loop/SKILL.md"))
        #expect(Data(AgentSkill.text.utf8) == file, "run scripts/generate-agent-guide.py")
        // What Codex requires of a SKILL.md, and what Claude Code recommends
        #expect(AgentSkill.text.hasPrefix("---\nname: mutation-test-loop\ndescription: "))
    }

    /// A skill is written into a new directory, left alone when it is the same, and never replaced when it differs
    /// unless --force says so (the difference may be the user's own edit).
    @Test func aSkillIsWrittenOnceAndNotReplacedSilently() throws {
        try withTemporaryDirectory { directory in
            let root = directory.appendingPathComponent("repo"), home = directory.appendingPathComponent("home")
            for (name, path) in [("claude", ".claude/skills/mutation-test-loop/SKILL.md"), ("codex", ".agents/skills/mutation-test-loop/SKILL.md")] {
                let file = root.appendingPathComponent(path)
                #expect(try AgentInstall.install(name, root: root, home: home, user: false, force: false).outcome == .created(file.path))
                #expect(try String(contentsOf: file, encoding: .utf8) == AgentSkill.text)
                #expect(try AgentInstall.install(name, root: root, home: home, user: false, force: false).outcome == .upToDate(file.path))
                try (AgentSkill.text + "my own note\n").write(to: file, atomically: true, encoding: .utf8)
                #expect(throws: AgentInstall.Failure.self) { try AgentInstall.install(name, root: root, home: home, user: false, force: false) }
                #expect(try String(contentsOf: file, encoding: .utf8).hasSuffix("my own note\n"))
                #expect(try AgentInstall.install(name, root: root, home: home, user: false, force: true).outcome == .updated(file.path))
                #expect(try String(contentsOf: file, encoding: .utf8) == AgentSkill.text)
                // --user: below the home directory that was given, nothing more in the repository
                #expect(try AgentInstall.install(name, root: root, home: home, user: true, force: false).outcome == .created(home.appendingPathComponent(path).path))
            }
            #expect(throws: AgentInstall.Failure.unknownTarget("cursor")) { try AgentInstall.install("cursor", root: root, home: home, user: false, force: false) }
            #expect(throws: AgentInstall.Failure.noUserPlace("agents-md")) { try AgentInstall.install("agents-md", root: root, home: home, user: true, force: false) }
            #expect(AgentInstall.Failure.unknownTarget("cursor").description.contains("agents-md"))
        }
    }

    /// AGENTS.md belongs to the user: it is created when missing, the section is added at its end otherwise, and a
    /// second run replaces only what is between the markers.
    @Test func theSectionInAgentsFileTouchesNothingElse() throws {
        try withTemporaryDirectory { root in
            let file = root.appendingPathComponent("AGENTS.md")
            func install() throws -> AgentInstall.Outcome { try AgentInstall.install("agents-md", root: root, home: root, user: false, force: false).outcome }
            #expect(try install() == .created(file.path))
            let created = try String(contentsOf: file, encoding: .utf8)
            #expect(created.hasPrefix("# AGENTS.md\n\n" + AgentInstall.beginMarker + "\n## Mutation testing"))
            #expect(created.hasSuffix(AgentInstall.endMarker + "\n"))
            #expect(created.contains("run `xcmutate agent-guide`"))
            #expect(try install() == .upToDate(file.path))

            // A file of the user: the section goes to the end, the rest stays
            try "# Project\n\nUse tabs.\n".write(to: file, atomically: true, encoding: .utf8)
            #expect(try install() == .updated(file.path))
            var text = try String(contentsOf: file, encoding: .utf8)
            #expect(text.hasPrefix("# Project\n\nUse tabs.\n\n" + AgentInstall.beginMarker + "\n"))
            #expect(try install() == .upToDate(file.path))

            // Text after the section, and an older section between the markers: only the section is replaced
            text = text.replacingOccurrences(of: "Do not run `xcmutate accept` without asking.", with: "An older line.") + "\n## After\n\nKeep me.\n"
            try text.write(to: file, atomically: true, encoding: .utf8)
            #expect(try install() == .updated(file.path))
            let replaced = try String(contentsOf: file, encoding: .utf8)
            #expect(replaced.hasPrefix("# Project\n\nUse tabs.\n\n" + AgentInstall.beginMarker))
            #expect(replaced.hasSuffix(AgentInstall.endMarker + "\n\n## After\n\nKeep me.\n"))
            #expect(!replaced.contains("An older line."))
            #expect(replaced.contains("Do not run `xcmutate accept` without asking."))

            // One marker without the other: nothing is guessed
            try (AgentInstall.beginMarker + "\nhalf\n").write(to: file, atomically: true, encoding: .utf8)
            #expect(throws: AgentInstall.Failure.brokenMarkers(path: file.path)) { try install() }
            #expect(try String(contentsOf: file, encoding: .utf8) == AgentInstall.beginMarker + "\nhalf\n")
        }
    }

    /// What `--install` chooses from the project: the skill for a `.claude` folder, the section for an AGENTS.md,
    /// both for both, and a new AGENTS.md for neither. A file named `.claude` is not the folder of Claude Code.
    @Test func installChoosesFromWhatTheProjectHas() throws {
        try withTemporaryDirectory { root in
            #expect(AgentInstall.detect(root: root).targets == ["agents-md"])
            try "".write(to: root.appendingPathComponent(".claude"), atomically: true, encoding: .utf8)
            #expect(AgentInstall.detect(root: root) == AgentInstall.Detection(claudeFolder: false, codexFolder: false, agentsFile: false))
            try FileManager.default.removeItem(at: root.appendingPathComponent(".claude"))
            try FileManager.default.createDirectory(at: root.appendingPathComponent(".claude"), withIntermediateDirectories: true)
            #expect(AgentInstall.detect(root: root).targets == ["claude"])
            try "# Mine\n".write(to: root.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
            #expect(AgentInstall.detect(root: root).targets == ["claude", "agents-md"])
            try FileManager.default.createDirectory(at: root.appendingPathComponent(".agents"), withIntermediateDirectories: true)
            #expect(AgentInstall.detect(root: root).targets == ["claude", "codex", "agents-md"])
            try FileManager.default.removeItem(at: root.appendingPathComponent(".claude"))
            try FileManager.default.removeItem(at: root.appendingPathComponent("AGENTS.md"))
            // Codex skills alone: no AGENTS.md is made
            #expect(AgentInstall.detect(root: root).targets == ["codex"])
            try FileManager.default.removeItem(at: root.appendingPathComponent(".agents"))
            try "# Mine\n".write(to: root.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
            #expect(AgentInstall.detect(root: root).targets == ["agents-md"])
        }
    }

    /// Through the command line, in the four kinds of project and from a subdirectory: the root of the repository,
    /// one line per file on standard output, nothing changed by a second run, nothing written to the home directory
    /// unless --install-for … --user says so, and no change to what `agent-guide` prints alone.
    @Test(.enabled(if: available)) func installThroughTheCommandLine() throws {
        let skill = ".claude/skills/mutation-test-loop/SKILL.md", codexSkill = ".agents/skills/mutation-test-loop/SKILL.md"
        func tool(_ arguments: [String], in directory: URL, home: URL) throws -> (status: Int32, out: String, err: String) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: try #require(Self.executable))
            process.arguments = arguments
            process.currentDirectoryURL = directory
            var environment = ProcessInfo.processInfo.environment
            environment["HOME"] = home.path
            process.environment = environment
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            try process.run()
            let printed = out.fileHandleForReading.readDataToEndOfFile(), complaints = err.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: printed, as: UTF8.self), String(decoding: complaints, as: UTF8.self))
        }
        for kind in ["claude", "codex", "agents", "both", "all", "neither"] {
            try withRepository { directory in
                let home = directory.appendingPathComponent("a-home"), sub = directory.appendingPathComponent("Sources")
                try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
                if ["claude", "both", "all"].contains(kind) {
                    try FileManager.default.createDirectory(at: directory.appendingPathComponent(".claude"), withIntermediateDirectories: true)
                }
                if ["codex", "all"].contains(kind) {
                    try FileManager.default.createDirectory(at: directory.appendingPathComponent(".agents"), withIntermediateDirectories: true)
                }
                if ["agents", "both", "all"].contains(kind) {
                    try "# Project\n\nUse tabs.\n".write(to: directory.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
                }
                let first = try tool(["agent-guide", "--install"], in: sub, home: home)
                #expect(first.status == 0, "\(kind): \(first.err)")
                #expect(first.err.isEmpty)
                let lines = first.out.split(separator: "\n").map(String.init)
                switch kind {
                case "claude":
                    #expect(lines == ["Found .claude/: wrote the Claude Code skill to \(skill)"])
                case "codex":
                    #expect(lines == ["Found .agents/: wrote the Codex skill to \(codexSkill)", AgentInstall.claudeHint])
                case "agents":
                    #expect(lines == ["Found AGENTS.md: wrote the xcmutate section into AGENTS.md", AgentInstall.claudeHint])
                case "all":
                    #expect(lines == ["Found .claude/: wrote the Claude Code skill to \(skill)", "Found .agents/: wrote the Codex skill to \(codexSkill)",
                                      "Found AGENTS.md: wrote the xcmutate section into AGENTS.md"])
                case "both":
                    #expect(lines == ["Found .claude/: wrote the Claude Code skill to \(skill)", "Found AGENTS.md: wrote the xcmutate section into AGENTS.md"])
                default:
                    #expect(lines.count == 2)
                    #expect(lines.first?.hasPrefix("No .claude/, .agents/ or AGENTS.md") == true)
                    #expect(lines.first?.hasSuffix(": created AGENTS.md with the xcmutate section") == true)
                    #expect(lines.last == AgentInstall.claudeHint)
                }
                let fm = FileManager.default
                #expect(fm.fileExists(atPath: directory.appendingPathComponent(skill).path) == ["claude", "both", "all"].contains(kind))
                #expect(fm.fileExists(atPath: directory.appendingPathComponent(codexSkill).path) == ["codex", "all"].contains(kind))
                #expect(fm.fileExists(atPath: directory.appendingPathComponent("AGENTS.md").path) == ["agents", "both", "all", "neither"].contains(kind))
                if ["agents", "both", "all"].contains(kind) {
                    #expect(try String(contentsOf: directory.appendingPathComponent("AGENTS.md"), encoding: .utf8).hasPrefix("# Project\n\nUse tabs.\n\n" + AgentInstall.beginMarker))
                }
                let second = try tool(["agent-guide", "--install"], in: sub, home: home)
                #expect(second.status == 0)
                #expect(second.out.split(separator: "\n").allSatisfy { $0.hasSuffix("is up to date; nothing was changed") || $0 == AgentInstall.claudeHint })
                #expect(try fm.contentsOfDirectory(atPath: home.path).isEmpty, "--install wrote to the home directory")
            }
        }
        try withRepository { directory in
            let home = directory.appendingPathComponent("a-home")
            // A skill that differs is not replaced, and the other file is still written; the run fails
            try FileManager.default.createDirectory(at: directory.appendingPathComponent(".claude/skills/mutation-test-loop"), withIntermediateDirectories: true)
            try "my own skill\n".write(to: directory.appendingPathComponent(skill), atomically: true, encoding: .utf8)
            try "# Mine\n".write(to: directory.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
            let refused = try tool(["agent-guide", "--install"], in: directory, home: home)
            #expect(refused.status != 0)
            #expect(refused.err.contains("--force"))
            #expect(refused.out == "Found AGENTS.md: wrote the xcmutate section into AGENTS.md\n")
            #expect(try String(contentsOf: directory.appendingPathComponent(skill), encoding: .utf8) == "my own skill\n")
            #expect(try tool(["agent-guide", "--install", "--force"], in: directory, home: home).status == 0)
            #expect(try String(contentsOf: directory.appendingPathComponent(skill), encoding: .utf8) == AgentSkill.text)

            // The explicit forms; --user only with a target, into HOME
            let codex = try tool(["agent-guide", "--install-for", "codex"], in: directory, home: home)
            #expect(codex.out == "Wrote the Codex skill to .agents/skills/mutation-test-loop/SKILL.md\n", "\(codex.err)")
            let user = try tool(["agent-guide", "--install-for", "claude", "--user"], in: directory, home: home)
            #expect(user.status == 0, "\(user.err)")
            #expect(user.out == "Wrote the Claude Code skill to \(home.appendingPathComponent(skill).path)\n")
            #expect(try tool(["agent-guide", "--install", "--user"], in: directory, home: home).status == 64)
            #expect(try tool(["agent-guide", "--user"], in: directory, home: home).status == 64)
            #expect(try tool(["agent-guide", "--install-for", "agents-md", "--user"], in: directory, home: home).status != 0)
            let unknown = try tool(["agent-guide", "--install-for", "somewhere"], in: directory, home: home)
            #expect(unknown.status == 64)
            #expect(unknown.out.isEmpty)
            #expect(unknown.err.contains("The targets are:") && unknown.err.contains("agents-md"))
            #expect(try tool(["agent-guide"], in: directory, home: home).out == AgentGuide.text)
        }
    }
}
