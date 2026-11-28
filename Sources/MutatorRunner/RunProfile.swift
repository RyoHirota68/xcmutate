import Foundation

/// The `run` options that the config file (`xcmutate.yml`) can hold, under `run` (for every run) and under `profiles.<name>`
/// (with `run --profile <name>`). This table is the one place where a key of the file and a command-line option are
/// tied together; a unit test checks every option against `run --help`.
///
/// A value is turned into the option it stands for and handed to the same parser as the command line, so a value
/// from the file is checked and recorded exactly like one typed (it is part of what `--resume` compares). The order:
/// the command line, then the profile, then `run`, then the defaults. An option given on the command line replaces
/// the file's value of that key (for a repeatable option, all of its values).
public enum RunProfile {
    public enum Kind: Sendable, Equatable {
        /// `"key": "value"` → `--option value`
        case string
        /// `"key": ["a", "b"]` (or one string) → `--option a --option b`
        case strings
        /// `"key": true` → `--option`; false gives nothing
        case flag
        /// `"key": 12` → `--option 12`
        case number
        /// `"sharedProcess": true | false | "auto"`
        case sharedProcess
    }

    public struct Key: Sendable, Equatable {
        public var name: String
        public var option: String
        public var kind: Kind
        /// A path: a leading `~/` is the home directory (a shell does that on the command line, the file needs it
        /// here), and a relative path is relative to the directory of the config file (the root), wherever the run is
        /// started from.
        public var isPath = false
    }

    public static let keys: [Key] = [
        Key(name: "workspace", option: "--workspace", kind: .string),
        Key(name: "project", option: "--project", kind: .string),
        Key(name: "package", option: "--package", kind: .string),
        Key(name: "scheme", option: "--scheme", kind: .string),
        Key(name: "destination", option: "--destination", kind: .strings),
        Key(name: "testPlan", option: "--test-plan", kind: .string),
        Key(name: "onlyTesting", option: "--only-testing", kind: .strings),
        Key(name: "skipTesting", option: "--skip-testing", kind: .strings),
        Key(name: "onlyTestConfiguration", option: "--only-test-configuration", kind: .strings),
        Key(name: "buildArg", option: "--build-arg", kind: .strings),
        Key(name: "packageCache", option: "--package-cache", kind: .string, isPath: true),
        Key(name: "since", option: "--since", kind: .string),
        Key(name: "selectTests", option: "--select-tests", kind: .string),
        Key(name: "impactMap", option: "--impact-map", kind: .string, isPath: true),
        Key(name: "writeImpactMap", option: "--write-impact-map", kind: .string, isPath: true),
        Key(name: "sharedProcess", option: "--shared-process", kind: .sharedProcess),
        Key(name: "workers", option: "--workers", kind: .number),
        Key(name: "confirmKills", option: "--confirm-kills", kind: .string),
        Key(name: "failUnder", option: "--fail-under", kind: .number),
        Key(name: "failOnSurvived", option: "--fail-on-survived", kind: .flag),
        Key(name: "baselineReport", option: "--baseline-report", kind: .string, isPath: true),
        Key(name: "stopWhenGateDecided", option: "--stop-when-gate-decided", kind: .flag),
        Key(name: "timeLimit", option: "--time-limit", kind: .string),
        Key(name: "maxMutants", option: "--max-mutants", kind: .number),
        Key(name: "reporter", option: "--reporter", kind: .strings),
        Key(name: "report", option: "--report", kind: .strings),
        Key(name: "workDir", option: "--work-dir", kind: .string, isPath: true),
    ]

    /// Values that make verdicts weaker, which the file cannot hold (the command line still can). As with
    /// `--no-recheck-survivors` and `--trust-shared-survivors`, which have no key at all, weakening the evidence has
    /// to be asked for where the run is started.
    static let weakeningValues: [String: Set<String>] = [
        "confirmKills": [KillConfirmation.none.rawValue],
    ]

    /// The arguments for one value: `--option value`, or `--option=value` when the value starts with `-` (the
    /// parser would take `-quiet` for an option of its own; the help of `--build-arg` asks for this form).
    static func arguments(_ option: String, _ value: String) -> [String] {
        value.hasPrefix("-") ? ["\(option)=\(value)"] : [option, value]
    }

    /// For a value that was read as a number or a boolean where a string is wanted (`timeLimit: 90`, `since: 1234567`):
    /// how to write it as a string.
    static func quoteHint(_ name: String, _ value: Any, _ url: URL) -> String {
        guard let number = value as? NSNumber else {
            if let list = value as? [Any], let first = list.first(where: { $0 is NSNumber }) as? NSNumber { return quoteHint(name, first, url) }
            return ""
        }
        let text = CFGetTypeID(number) == CFBooleanGetTypeID() ? (number.boolValue ? "true" : "false") : number.stringValue
        return ConfigFile.format(of: url) == .json ? "; write it in quotes: \"\(name)\": \"\(text)\"" : "; write it in quotes: \(name): \"\(text)\""
    }

    /// `~/…` with the home directory put in.
    static func expandingHome(_ path: String) -> String {
        path == "~" || path.hasPrefix("~/") ? (path as NSString).expandingTildeInPath : path
    }

    /// A path of the file as the run takes it: the home directory put in, and a relative path made absolute from the
    /// directory of the config file.
    static func resolvedPath(_ path: String, configDirectory: URL) -> String {
        let expanded = expandingHome(path)
        if expanded.hasPrefix("/") { return expanded }
        return URL(fileURLWithPath: expanded, relativeTo: URL(fileURLWithPath: configDirectory.path, isDirectory: true)).standardizedFileURL.path
    }

    /// What the file contributed: the arguments to put before the command line's, where each key came from, and
    /// problems (unknown keys; a key of the wrong type stops the run).
    public struct Expansion: Sendable, Equatable {
        public var arguments: [String] = []
        /// Key → "profile <name>" or "config" (only the keys that were used).
        public var sources: [String: String] = [:]
        /// Key → its value as text, for the record of the run.
        public var values: [String: String] = [:]
        /// Keys of the file that the command line replaced.
        public var overridden: [String] = []
        public var warnings: [String] = []
        public var profile: String?
        public var file: String?

        public init() {}
    }

    public struct Failure: Error, CustomStringConvertible, Equatable {
        public var description: String
    }

    /// The arguments for the `run` options of the config file at `url` (common `run` and profile `profile`) that the
    /// command line `given` does not set itself. Errors and warnings end with where the keys are documented.
    public static func expand(configAt url: URL, profile: String?, given: [String]) throws -> Expansion {
        let link = "see \(ConfigFile.runOptionsDocumentation)"
        do {
            var result = try expandUnlinked(configAt: url, profile: profile, given: given)
            result.warnings = result.warnings.map { "\($0); \(link)" }
            return result
        } catch let failure as Failure {
            throw Failure(description: "\(failure.description); \(link)")
        }
    }

    static func expandUnlinked(configAt url: URL, profile: String?, given: [String]) throws -> Expansion {
        var result = Expansion()
        result.profile = profile
        guard FileManager.default.fileExists(atPath: url.path) else {
            if let profile { throw Failure(description: "--profile \(profile): there is no config file at \(url.path)") }
            return result
        }
        let top: [String: Any]
        do {
            guard let found = try ConfigFile.object(at: url) else { return result }
            top = found
        } catch {
            throw Failure(description: "\(error)")
        }
        result.file = url.path
        var merged: [String: (value: Any, source: String)] = [:]
        // A key whose children are all commented out is null in YAML: nothing, as an empty object
        if let common = top["run"], !(common is NSNull) {
            guard let object = common as? [String: Any] else { throw Failure(description: "\(url.lastPathComponent): `run` must be an object") }
            for (key, value) in object { merged[key] = (value, "config") }
        }
        if let profile {
            guard let profiles = top["profiles"] as? [String: Any], let chosen = profiles[profile] else {
                let names = ((top["profiles"] as? [String: Any])?.keys.sorted() ?? []).joined(separator: ", ")
                throw Failure(description: "--profile \(profile): \(url.lastPathComponent) has no such profile (profiles: \(names.isEmpty ? "none" : names))")
            }
            guard let object = chosen is NSNull ? [:] : chosen as? [String: Any] else { throw Failure(description: "\(url.lastPathComponent): `profiles.\(profile)` must be an object") }
            for (key, value) in object { merged[key] = (value, "profile \(profile)") }
        }
        if let profiles = top["profiles"], !(profiles is [String: Any]), !(profiles is NSNull) {
            throw Failure(description: "\(url.lastPathComponent): `profiles` must be an object of profiles by name")
        }
        let byName = Dictionary(uniqueKeysWithValues: keys.map { ($0.name, $0) })
        for name in merged.keys.sorted() {
            guard let (value, source) = merged[name] else { continue }
            if ConfigFile.isComment(name, in: url) { continue }
            guard let key = byName[name] else {
                result.warnings.append("\(url.lastPathComponent): unknown run option `\(name)` in \(source == "config" ? "`run`" : "`profiles.\(profile ?? "")`") is ignored (known: \(keys.map(\.name).joined(separator: ", ")))")
                continue
            }
            if let weak = weakeningValues[name], let text = value as? String, weak.contains(text.lowercased()) {
                throw Failure(description: "\(url.lastPathComponent): `\(name)` (\(source)) cannot be \"\(text)\": it makes verdicts weaker (a failing run would count as a kill without the tests passing again without mutants), so it can be given only on the command line (\(key.option) \(text))")
            }
            let flags = key.kind == .sharedProcess ? ["--shared-process", "--shared-process=auto", "--shared-process-auto"] : [key.option]
            if given.contains(where: { argument in flags.contains { argument == $0 || argument.hasPrefix($0 + "=") } }) {
                result.overridden.append(name)
                continue
            }
            let place = "\(url.lastPathComponent): `\(name)` (\(source))"
            switch key.kind {
            case .string:
                guard var text = value as? String else { throw Failure(description: "\(place) must be a string\(Self.quoteHint(name, value, url))") }
                if key.isPath { text = resolvedPath(text, configDirectory: url.deletingLastPathComponent()) }
                result.arguments += arguments(key.option, text)
                result.values[name] = text
            case .strings:
                let list: [String]
                if let text = value as? String { list = [text] } else if let array = value as? [String] { list = array } else {
                    throw Failure(description: "\(place) must be a string or an array of strings\(Self.quoteHint(name, value, url))")
                }
                for item in list { result.arguments += arguments(key.option, key.isPath ? resolvedPath(item, configDirectory: url.deletingLastPathComponent()) : item) }
                result.values[name] = list.joined(separator: ", ")
            case .flag:
                guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
                    throw Failure(description: "\(place) must be true or false")
                }
                if number.boolValue { result.arguments.append(key.option) }
                result.values[name] = String(number.boolValue)
            case .number:
                guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { throw Failure(description: "\(place) must be a number") }
                // Beyond what a Double holds exactly, `intValue` would be some other number
                guard number.doubleValue.isFinite, abs(number.doubleValue) <= 9_007_199_254_740_991 else { throw Failure(description: "\(place): the number \(number) is out of range") }
                let text = number.doubleValue == number.doubleValue.rounded() ? String(number.intValue) : number.stringValue
                result.arguments += [key.option, text]
                result.values[name] = text
            case .sharedProcess:
                if let text = value as? String, text == "auto" {
                    result.arguments.append("--shared-process-auto")
                    result.values[name] = "auto"
                } else if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
                    if number.boolValue { result.arguments.append("--shared-process") }
                    result.values[name] = String(number.boolValue)
                } else {
                    throw Failure(description: "\(place) must be true, false or \"auto\"")
                }
            }
            result.sources[name] = source
        }
        return result
    }
}
