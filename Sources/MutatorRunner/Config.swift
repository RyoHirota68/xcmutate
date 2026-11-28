import Foundation
import MutatorCore

/// `xcmutate.yml` (placed at the project root and committed; `xcmutate.config.json` of earlier versions is read too,
/// `ConfigFile`).
///
/// ```yaml
/// aridCalls: [Crashlytics, LoginAnalytics, sendAnalytics]
/// disabledOperators: [normalization-removal]
/// maxSwitchesPerExpression: 8
/// ```
public struct MutatorConfig: Codable, Sendable {
    public static let defaultName = ToolNaming.configFileName

    /// Calls that are not mutated (both the expressions in their arguments and the statement removal of the call).
    public var aridCalls: [String]?
    /// Operators not to use (`MutationOperator` values).
    public var disabledOperators: [String]?
    /// Operators to use among those not used by default.
    public var enabledOperators: [String]?
    public var maxSwitchesPerExpression: Int?
    /// Files excluded from the targets (globs in gitignore syntax; paths relative to the root; a leading `!` brings a file back).
    /// Applied from top to bottom after the default exclusions (tests, generated code, etc.; `FileSelector`).
    public var exclude: [String]?
    /// Declarations whose bodies are not mutated, by name (`*` stands for any text): `["*ForTesting", "_reset*"]`.
    public var excludeDeclarations: [String]?

    /// Problems noticed while loading (unknown keys, etc.). Not written to the config file.
    public var loadWarnings: [String] = []

    enum CodingKeys: String, CodingKey, CaseIterable {
        case aridCalls, disabledOperators, enabledOperators, maxSwitchesPerExpression, exclude, excludeDeclarations
    }

    public init() {}

    /// Reads the config file (YAML or JSON, `ConfigFile`). An empty configuration if it does not exist. If it cannot be
    /// read or a type does not match, throws an error with the file name.
    /// Unknown keys (typos) are not silently ignored but put into `loadWarnings`.
    public static func load(_ url: URL) throws -> MutatorConfig {
        guard let dictionary = try ConfigFile.object(at: url) else { return MutatorConfig() }
        // The keys of this type, as JSON for the decoder (a YAML file is read into the same values first)
        let ownKeys = Set(CodingKeys.allCases.map(\.stringValue))
        let own = dictionary.filter { ownKeys.contains($0.key) && !($0.value is NSNull) }
        // A number that JSON cannot hold (`1e400` read as infinity) would stop the process in JSONSerialization
        guard JSONSerialization.isValidJSONObject(own) else { throw ConfigError.invalid(url.path, "a number is out of range") }
        let data = try JSONSerialization.data(withJSONObject: own)
        var config: MutatorConfig
        do {
            config = try JSONDecoder().decode(MutatorConfig.self, from: data)
        } catch let DecodingError.typeMismatch(_, context) {
            throw ConfigError.invalid(url.path, "`\(context.codingPath.map(\.stringValue).joined(separator: "."))`: \(context.debugDescription)")
        } catch {
            throw ConfigError.invalid(url.path, "\(error)")
        }
        // `run` and `profiles` hold run options; `RunProfile` reads them (and warns about their unknown keys)
        let known = Set(CodingKeys.allCases.map(\.stringValue)).union(["run", "profiles"])
        // In JSON, keys that start with `_` are explanations (`xcmutate init` wrote its reasons there before YAML)
        for key in dictionary.keys.sorted() where !known.contains(key) && !ConfigFile.isComment(key, in: url) {
            config.loadWarnings.append("\(url.lastPathComponent): unknown key `\(key)` is ignored (known keys: \(known.sorted().joined(separator: ", "))\(key.hasPrefix("_") ? "; write explanations as comments" : ""); see \(ConfigFile.keysDocumentation))")
        }
        return config
    }

    /// Builds the generation options from the config file and the command-line arguments (the command-line values are added to those of the config file).
    public func generatorOptions(extraArid: [String], extraDisabled: [String], maxSwitches: Int?, extraEnabled: [String] = []) throws -> GeneratorOptions {
        var options = GeneratorOptions()
        options.aridCallPatterns = (aridCalls ?? []) + extraArid
        options.excludedDeclarationPatterns = excludeDeclarations ?? []
        for name in (enabledOperators ?? []) + extraEnabled {
            guard let op = MutationOperator(rawValue: name) else { throw ConfigError.unknownOperator(name) }
            options.operators.insert(op)
        }
        for name in (disabledOperators ?? []) + extraDisabled {
            guard let op = MutationOperator(rawValue: name) else {
                throw ConfigError.unknownOperator(name)
            }
            options.operators.remove(op)
        }
        if let max = maxSwitches ?? maxSwitchesPerExpression { options.maxSwitchesPerExpression = max }
        return options
    }

    public enum ConfigError: Error, CustomStringConvertible {
        case unknownOperator(String)
        case invalid(String, String)
        public var description: String {
            switch self {
            case let .invalid(path, message):
                "\(path): \(message)"
            case let .unknownOperator(name):
                "unknown operator \(name); known: \(MutationOperator.allCases.map(\.rawValue).joined(separator: ", "))"
            }
        }
    }
}
