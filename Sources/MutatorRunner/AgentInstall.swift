import Foundation

/// `xcmutate agent-guide --install`: writes the file through which a coding agent finds the guide.
///
/// Without a target the project decides (`detect`): a `.claude/` folder gets the Claude Code skill, an `.agents/`
/// folder the Codex skill, an `AGENTS.md` the section, and a project with none of them a new `AGENTS.md`. `--install-for <target>`
/// names one target, and only that form writes to the home directory (`--user`).
///
/// One entry per place an agent reads its instructions from. An entry says where the file goes, what goes into it,
/// and how a file that is already there is treated: a file the tool owns as a whole (the skill) is never replaced
/// when it differs, unless `--force` is given; in a file that belongs to the user (AGENTS.md) only the part between
/// two marker comments is the tool's, and nothing outside it is touched.
public enum AgentInstall {
    public struct Target: Sendable {
        /// The value of `--install`.
        public var name: String
        /// One line for the list of targets: what is written and who reads it.
        public var summary: String
        /// What is written, for the line printed after the install ("the Claude Code skill").
        public var what: String
        /// The path below the base directory (the repository root, or the home directory with `--user`).
        public var relativePath: String
        /// The path below the home directory for `--user`; nil if the target has no user-wide place.
        public var userRelativePath: String?
        public var content: Content
    }

    public enum Content: Sendable {
        /// The whole file is the tool's.
        case wholeFile(String)
        /// A section of a file that the user owns, between `beginMarker` and `endMarker`.
        case section(String)
    }

    public static let beginMarker = "<!-- xcmutate:begin (written by `xcmutate agent-guide --install`; edit outside these markers) -->"
    public static let endMarker = "<!-- xcmutate:end -->"

    /// The section for AGENTS.md: short, because the procedure itself is printed by the tool.
    public static let agentsSection = """
    ## Mutation testing (xcmutate)

    When you are asked to check or strengthen tests with mutation testing (to find gaps in the tests, to kill \
    surviving mutants), run `xcmutate agent-guide`, read all of its output and follow it. The guide is the one of the \
    installed version of the tool.

    These rules hold even before you have read the guide:

    - Do not change production code to make a mutant go away. Report a bug you find and ask.
    - Do not run `xcmutate accept` without asking.
    - Do not start a run that you expect to take more than 15 minutes without asking.
    """

    public static let targets: [Target] = [
        Target(name: "claude",
               summary: "Claude Code skill: .claude/skills/mutation-test-loop/SKILL.md",
               what: "the Claude Code skill",
               relativePath: ".claude/skills/mutation-test-loop/SKILL.md",
               userRelativePath: ".claude/skills/mutation-test-loop/SKILL.md",
               content: .wholeFile(AgentSkill.text)),
        // Codex reads skills of the same form from `.agents/skills` (from the working directory up to the repository
        // root) and `$HOME/.agents/skills`; its SKILL.md must have `name` and `description`, which the skill has
        // (learn.chatgpt.com/docs/build-skills, "Where Codex loads local skills", read 2026-11-24)
        Target(name: "codex",
               summary: "Codex skill: .agents/skills/mutation-test-loop/SKILL.md",
               what: "the Codex skill",
               relativePath: ".agents/skills/mutation-test-loop/SKILL.md",
               userRelativePath: ".agents/skills/mutation-test-loop/SKILL.md",
               content: .wholeFile(AgentSkill.text)),
        Target(name: "agents-md",
               summary: "A section in AGENTS.md (Codex, Cursor, GitHub Copilot agent)",
               what: "the xcmutate section",
               relativePath: "AGENTS.md",
               userRelativePath: nil,
               content: .section(agentsSection)),
    ]

    /// The list printed when `--install-for` names no known target.
    public static var targetList: String {
        targets.map { "  \($0.name.padding(toLength: 10, withPad: " ", startingAt: 0)) \($0.summary)" }.joined(separator: "\n")
    }

    public enum Outcome: Equatable, Sendable {
        case created(String)
        case updated(String)
        case upToDate(String)

        public var path: String {
            switch self {
            case let .created(path), let .updated(path), let .upToDate(path): return path
            }
        }
    }

    public enum Failure: Error, CustomStringConvertible, Equatable {
        case unknownTarget(String)
        case noUserPlace(String)
        case differs(path: String, what: String)
        case brokenMarkers(path: String)
        case cannotWrite(path: String, reason: String)

        public var description: String {
            switch self {
            case let .unknownTarget(name):
                return "--install-for \(name): there is no such target. The targets are:\n\(AgentInstall.targetList)"
            case let .noUserPlace(name):
                return "--install-for \(name) has no user-wide place: --user works with \(AgentInstall.targets.filter { $0.userRelativePath != nil }.map(\.name).joined(separator: " and ")). Run it without --user in the repository."
            case let .differs(path, what):
                return "\(path) exists and differs from what this version of the tool writes (\(what)). Nothing was changed. If the differences are your own edits, keep the file; to replace it, run the command again with --force."
            case let .brokenMarkers(path):
                return "\(path) has one of the two markers of the tool's section without the other (\(AgentInstall.beginMarker.prefix(22))… / \(AgentInstall.endMarker)). Nothing was changed. Remove the leftover marker, or restore the pair, and run the command again."
            case let .cannotWrite(path, reason):
                return "\(path) could not be written: \(reason)"
            }
        }
    }

    /// Writes the file of `name`.
    /// - Parameters:
    ///   - root: the repository root (or the current directory outside a repository).
    ///   - home: the home directory, used with `user`.
    public static func install(_ name: String, root: URL, home: URL, user: Bool, force: Bool) throws -> (outcome: Outcome, target: Target) {
        guard let target = targets.first(where: { $0.name == name }) else { throw Failure.unknownTarget(name) }
        let file: URL
        if user {
            guard let relative = target.userRelativePath else { throw Failure.noUserPlace(name) }
            file = home.appendingPathComponent(relative)
        } else {
            file = root.appendingPathComponent(target.relativePath)
        }
        let fm = FileManager.default
        let existing = fm.fileExists(atPath: file.path) ? (try? String(contentsOf: file, encoding: .utf8)) : nil
        if fm.fileExists(atPath: file.path), existing == nil {
            throw Failure.cannotWrite(path: file.path, reason: "the file that is there is not UTF-8 text")
        }
        let wanted: String
        switch target.content {
        case let .wholeFile(text):
            if let existing {
                if existing == text { return (.upToDate(file.path), target) }
                guard force else { throw Failure.differs(path: file.path, what: difference(existing, text)) }
            }
            wanted = text
        case let .section(section):
            let block = beginMarker + "\n" + section + "\n" + endMarker
            if let existing {
                let begins = existing.components(separatedBy: beginMarker).count - 1
                let ends = existing.components(separatedBy: endMarker).count - 1
                if begins == 0, ends == 0 {
                    // The user's file: the section goes to its end, after one empty line
                    wanted = existing + (existing.isEmpty || existing.hasSuffix("\n\n") ? "" : existing.hasSuffix("\n") ? "\n" : "\n\n") + block + "\n"
                } else if begins == 1, ends == 1, let begin = existing.range(of: beginMarker), let end = existing.range(of: endMarker),
                          begin.upperBound <= end.lowerBound {
                    // Only what lies between the markers is replaced
                    wanted = String(existing[..<begin.lowerBound]) + block + String(existing[end.upperBound...])
                } else {
                    throw Failure.brokenMarkers(path: file.path)
                }
                if wanted == existing { return (.upToDate(file.path), target) }
            } else {
                wanted = "# AGENTS.md\n\n" + block + "\n"
            }
        }
        do {
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try wanted.write(to: file, atomically: true, encoding: .utf8)
        } catch {
            throw Failure.cannotWrite(path: file.path, reason: error.localizedDescription)
        }
        return (existing == nil ? .created(file.path) : .updated(file.path), target)
    }

    /// Where two texts differ, in a few words: the first line that is not the same.
    static func difference(_ existing: String, _ wanted: String) -> String {
        let a = existing.components(separatedBy: "\n"), b = wanted.components(separatedBy: "\n")
        let index = zip(a, b).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? min(a.count, b.count)
        let line = index < a.count ? a[index].trimmingCharacters(in: .whitespaces) : ""
        let shown = line.isEmpty ? "the file there is shorter" : "the first difference is in line \(index + 1): \"\(line.prefix(60))\(line.count > 60 ? "…" : "")\""
        return "\(a.count - 1) lines there, \(b.count - 1) here; \(shown)"
    }

    /// What `detect` found in the project, and the targets it chose.
    public struct Detection: Equatable, Sendable {
        public var claudeFolder: Bool
        /// `.agents/`, where Codex looks for skills.
        public var codexFolder: Bool = false
        public var agentsFile: Bool
        /// None of the three: a new AGENTS.md is written.
        public var nothing: Bool { !claudeFolder && !codexFolder && !agentsFile }
        /// The targets to write, in this order.
        public var targets: [String] {
            var names: [String] = []
            if claudeFolder { names.append("claude") }
            if codexFolder { names.append("codex") }
            if agentsFile || nothing { names.append("agents-md") }
            return names
        }
    }

    /// Looks at the project root: a `.claude` folder, an `.agents` folder, an `AGENTS.md` file. Nothing in the home
    /// directory.
    public static func detect(root: URL) -> Detection {
        func folder(_ name: String) -> Bool {
            var isFolder: ObjCBool = false
            return FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path, isDirectory: &isFolder) && isFolder.boolValue
        }
        let agents = FileManager.default.fileExists(atPath: root.appendingPathComponent("AGENTS.md").path)
        return Detection(claudeFolder: folder(".claude"), codexFolder: folder(".agents"), agentsFile: agents)
    }

    /// The line printed for one target: what was found that made the choice (nil for `--install-for`), and what
    /// was done.
    /// A path below `root` is shown relative to it (`AGENTS.md`); without `root` (with --user) in full.
    public static func message(_ outcome: Outcome, target: Target, found: String?, root: URL?) -> String {
        let prefix = root.map { $0.standardizedFileURL.path + "/" }
        let path = prefix.map { outcome.path.hasPrefix($0) ? String(outcome.path.dropFirst($0.count)) : outcome.path } ?? outcome.path
        let done: String
        switch (outcome, target.content) {
        case (.created, .wholeFile): done = "wrote \(target.what) to \(path)"
        case (.updated, .wholeFile): done = "replaced \(target.what) in \(path)"
        case (.created, .section): done = "created \(path) with \(target.what)"
        case (.updated, .section): done = "wrote \(target.what) into \(path)"
        case (.upToDate, _): done = "\(target.what) in \(path) is up to date; nothing was changed"
        }
        guard let found else { return done.prefix(1).uppercased() + done.dropFirst() }
        return found + ": " + done
    }

    /// Why `detect` chose a target, for the start of its line.
    public static func reason(_ name: String, _ detection: Detection) -> String {
        switch name {
        case "claude": return "Found .claude/"
        case "codex": return "Found .agents/"
        default: return detection.agentsFile ? "Found AGENTS.md" : "No .claude/, .agents/ or AGENTS.md (Codex, Cursor and GitHub Copilot read AGENTS.md)"
        }
    }

    /// Printed when the project has no `.claude` folder: how to add the Claude Code skill as well.
    public static let claudeHint = "For Claude Code, also run: \(ToolInfo.name) agent-guide --install-for claude"
}
