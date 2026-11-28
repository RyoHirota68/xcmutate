import Foundation
import MutatorCore
import Yams

/// The config file: `xcmutate.yml` at the root (YAML, so that it can carry comments), or `xcmutate.config.json`, the
/// name and format of versions up to 0.14, which is still read. A path given with `--config` is read as JSON when it
/// ends in `.json` and as YAML otherwise.
///
/// YAML is read with the scalar types of YAML 1.2's JSON schema, not those of YAML 1.1: only `true` and `false` are
/// booleans, only decimal numbers are numbers, `null`, `~` and an empty value are null, and every other value without
/// quotes is a string. `yes`, `no`, `on` and `off` therefore stay strings, and a key that expects a boolean rejects
/// them, as it rejects `"yes"` in JSON; `3h` is a string; `0.15` and `08` are numbers only where they look like
/// decimal numbers; a number out of range is refused. An alias stands for the value of its anchor; a merge key (`<<`), a
/// key that is there twice, and a tag other than the standard ones (or one that does not agree with its value) are
/// refused.
public enum ConfigFile {
    public static let yamlName = ToolNaming.configFileName
    /// Also found at the root (a name that people try).
    public static let yamlAlternativeName = "xcmutate.yaml"
    /// The file of versions up to 0.14.
    public static let jsonName = "xcmutate.config.json"

    public enum Format: Equatable, Sendable { case json, yaml }

    public static func format(of url: URL) -> Format {
        url.pathExtension.lowercased() == "json" ? .json : .yaml
    }

    /// Where the run options and their keys are documented (the documentation of this version).
    public static let runOptionsDocumentation = ToolInfo.documentation("usage.md", anchor: "run-options-in-the-config-file-run-and-profiles")
    /// Where the other keys are documented.
    public static let keysDocumentation = ToolInfo.documentation("configuration.md")

    public struct Ambiguous: Error, CustomStringConvertible, Equatable {
        public var paths: [String]
        public var description: String {
            let names = paths.map { URL(fileURLWithPath: $0).lastPathComponent }
            let yamls = names.filter { $0 != jsonName }
            let how = yamls.count == 1
                ? "\(jsonName) is the file of versions up to 0.14: `\(ToolInfo.name) init --force` moves its settings into \(yamls[0]) and removes it (or move them by hand), or name one file with --config"
                : "keep one of \(yamls.joined(separator: " and ")), or name one file with --config"
            return "more than one config file at the root: \(paths.joined(separator: ", ")). \(how). See \(runOptionsDocumentation)"
        }
    }

    /// The config file at `root`: the one that exists, or `root/xcmutate.yml` when none does. Throws when more than
    /// one exists, so that which one is read is never a silent choice.
    public static func locate(root: URL) throws -> URL {
        let found = [yamlName, yamlAlternativeName, jsonName].map { root.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        if found.count > 1 { throw Ambiguous(paths: found.map(\.path)) }
        return found.first ?? root.appendingPathComponent(yamlName)
    }

    /// The top-level object of the file at `url`; nil when the file does not exist. Throws `MutatorConfig.ConfigError`
    /// when it cannot be read.
    public static func object(at url: URL) throws -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        let object: Any
        switch format(of: url) {
        case .json:
            do {
                object = try JSONSerialization.jsonObject(with: data)
            } catch {
                throw MutatorConfig.ConfigError.invalid(url.path, "not valid JSON: \((error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String ?? error.localizedDescription)")
            }
        case .yaml:
            do {
                object = try yamlValue(String(decoding: data, as: UTF8.self)) ?? [String: Any]()
            } catch let failure as Failure {
                throw MutatorConfig.ConfigError.invalid(url.path, "not valid YAML: \(failure.description)")
            } catch {
                throw MutatorConfig.ConfigError.invalid(url.path, "not valid YAML: \(error)")
            }
        }
        guard let dictionary = object as? [String: Any] else {
            throw MutatorConfig.ConfigError.invalid(url.path, "the top level must be \(format(of: url) == .json ? "a JSON object" : "a mapping of keys to values")")
        }
        return dictionary
    }

    /// In JSON, keys that start with `_` are explanations (`init` wrote its reasons there before YAML); YAML has
    /// comments for that.
    public static func isComment(_ key: String, in url: URL) -> Bool {
        format(of: url) == .json && key.hasPrefix("_")
    }

    struct Failure: Error, CustomStringConvertible {
        var description: String
    }

    /// The value of a YAML document as `[String: Any]`, `[Any]`, `String`, `Bool`, `Int`, `Double` and `NSNull`;
    /// nil for an empty document.
    static func yamlValue(_ text: String) throws -> Any? {
        guard let node = try Yams.compose(yaml: text) else { return nil }
        return try value(of: node)
    }

    static func value(of node: Node) throws -> Any {
        switch node {
        case let .scalar(scalar):
            return try value(of: scalar)
        case let .sequence(sequence):
            try check(sequence.tag, standard: "tag:yaml.org,2002:seq", mark: sequence.mark)
            return try sequence.map { try value(of: $0) }
        case let .mapping(mapping):
            try check(mapping.tag, standard: "tag:yaml.org,2002:map", mark: mapping.mark)
            var result: [String: Any] = [:]
            for (key, item) in mapping {
                guard case let .scalar(name) = key else { throw Failure(description: "\(place(key.mark))a key must be a plain name") }
                // A merge key would be read as a key named `<<`, and the keys it was meant to bring (a gate, say)
                // would be missing without an error
                if name.string == "<<", name.style == .plain || name.style == .any {
                    throw Failure(description: "\(place(key.mark))merge keys (`<<`) are not supported; write the keys out")
                }
                guard result[name.string] == nil else { throw Failure(description: "\(place(key.mark))the key `\(name.string)` is there twice") }
                result[name.string] = try value(of: item)
            }
            return result
        case let .alias(alias):
            // `compose` replaces an alias by the node of its anchor, so this is not reached; refused should it be
            throw Failure(description: "\(place(alias.mark))an alias could not be resolved")
        }
    }

    /// A collection may carry no tag, or its standard one.
    static func check(_ tag: Tag, standard: String, mark: Mark?) throws {
        let name = tag.description
        guard name.isEmpty || name == "!" || name == standard else { throw Failure(description: "\(place(mark))the tag \(name) is not supported") }
    }

    static func value(of scalar: Node.Scalar) throws -> Any {
        let text = scalar.string
        let tag = scalar.tag.description
        let quoted = scalar.style != .plain && scalar.style != .any
        // A quoted value, or one tagged as a string, is a string whatever it looks like
        if tag == "tag:yaml.org,2002:str" || (quoted && (tag.isEmpty || tag == "!")) { return text }
        if quoted { throw Failure(description: "\(place(scalar.mark))the tag \(tag) is not supported on a quoted value") }
        if tag == "!" { return text }
        // YAML 1.2, JSON schema
        let value: Any
        if text == "true" {
            value = true
        } else if text == "false" {
            value = false
        } else if text == "null" || text == "~" || text.isEmpty {
            value = NSNull()
        } else if text.range(of: #"^-?(0|[1-9][0-9]*)$"#, options: .regularExpression) != nil {
            guard let number = Int(text) else { throw Failure(description: "\(place(scalar.mark))the number \(text) is out of range") }
            value = number
        } else if text.range(of: #"^-?(0|[1-9][0-9]*)(\.[0-9]*)?([eE][-+]?[0-9]+)?$"#, options: .regularExpression) != nil {
            guard let number = Double(text), number.isFinite else { throw Failure(description: "\(place(scalar.mark))the number \(text) is out of range") }
            value = number
        } else {
            value = text
        }
        // No tag: the value as resolved. A standard tag must agree with it
        let agrees: Bool
        switch tag {
        case "": agrees = true
        case "tag:yaml.org,2002:null": agrees = value is NSNull
        case "tag:yaml.org,2002:bool": agrees = value is Bool
        case "tag:yaml.org,2002:int": agrees = value is Int
        case "tag:yaml.org,2002:float": agrees = value is Double || value is Int
        default: throw Failure(description: "\(place(scalar.mark))the tag \(tag) is not supported")
        }
        guard agrees else { throw Failure(description: "\(place(scalar.mark))`\(text)` is not a value of the tag \(tag)") }
        return value
    }

    static func place(_ mark: Mark?) -> String {
        mark.map { "line \($0.line), column \($0.column): " } ?? ""
    }

    // MARK: Writing

    /// A YAML scalar or block for `value` (what `yamlValue` reads back as the same value). Strings are always
    /// double-quoted, so that no string is read as another type.
    static func yaml(_ value: Any, indent: Int) -> String {
        let pad = String(repeating: " ", count: indent)
        switch value {
        case let dictionary as [String: Any]:
            if dictionary.isEmpty { return " {}" }
            return "\n" + dictionary.keys.sorted().map { key in "\(pad)\(yamlKey(key)):\(yaml(dictionary[key]!, indent: indent + 2))" }.joined(separator: "\n")
        case let array as [Any]:
            if array.isEmpty { return " []" }
            return "\n" + array.map { item in
                if let nested = item as? [String: Any], !nested.isEmpty {
                    // `- key: value` with the other keys under it
                    let lines = yaml(nested, indent: indent + 2).dropFirst().split(separator: "\n", omittingEmptySubsequences: false)
                    return "\(pad)- " + lines.enumerated().map { $0.offset == 0 ? String($0.element.dropFirst(indent + 2)) : String($0.element) }.joined(separator: "\n")
                }
                return "\(pad)-\(yaml(item, indent: indent + 2))"
            }.joined(separator: "\n")
        default:
            return " " + scalar(value)
        }
    }

    static func scalar(_ value: Any) -> String {
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
            if number.doubleValue == number.doubleValue.rounded(), abs(number.doubleValue) < 1e15 { return String(number.int64Value) }
            return number.stringValue
        }
        if value is NSNull { return "null" }
        return quoted("\(value)")
    }

    /// A double-quoted YAML string.
    static func quoted(_ text: String) -> String {
        var result = "\""
        for character in text.unicodeScalars {
            switch character {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\t": result += "\\t"
            case "\r": result += "\\r"
            case "\u{85}": result += "\\N"
            case "\u{2028}": result += "\\L"
            case "\u{2029}": result += "\\P"
            default:
                let value = character.value
                // Control characters, and the noncharacters, which YAML does not allow as they are
                if value < 0x20 || (0x7f...0x9f).contains(value) {
                    result += String(format: "\\x%02x", value)
                } else if (0xfdd0...0xfdef).contains(value) || value & 0xfffe == 0xfffe || (0xd800...0xdfff).contains(value) {
                    result += value > 0xffff ? String(format: "\\U%08x", value) : String(format: "\\u%04x", value)
                } else {
                    result.unicodeScalars.append(character)
                }
            }
        }
        return result + "\""
    }

    static func yamlKey(_ key: String) -> String {
        key.range(of: #"^[A-Za-z][A-Za-z0-9_-]*$"#, options: .regularExpression) != nil ? key : quoted(key)
    }

    /// A comment of one or more lines at `indent` (lines are wrapped at about 110 characters).
    static func comment(_ text: String, indent: Int) -> String {
        let pad = String(repeating: " ", count: indent)
        var lines: [String] = []
        var line = ""
        for word in text.split(separator: " ", omittingEmptySubsequences: true) {
            if !line.isEmpty, line.count + word.count + 1 > 110 - indent {
                lines.append(line)
                line = ""
            }
            line += (line.isEmpty ? "" : " ") + word
        }
        if !line.isEmpty { lines.append(line) }
        return lines.map { "\(pad)# \($0)" }.joined(separator: "\n")
    }

    /// The text of the file without the top-level `keys` (each from its line to the next top-level key; comments and
    /// blank lines right before that key stay with it). For `init --force`, which replaces `run` and `profiles` and
    /// keeps the rest of the file as it was written, comments included.
    static func removingTopLevel(_ keys: Set<String>, from text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        func topLevelKey(_ line: String) -> String? {
            guard let first = line.first, first != " ", first != "\t", first != "#", first != "-" else { return nil }
            guard let colon = line.firstIndex(of: ":") else { return nil }
            return String(line[..<colon]).trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
        }
        var result: [String] = []
        var index = 0
        while index < lines.count {
            if let key = topLevelKey(lines[index]), keys.contains(key) {
                var end = index + 1
                while end < lines.count, topLevelKey(lines[end]) == nil, !(lines[end].hasPrefix("---") || lines[end].hasPrefix("...")) { end += 1 }
                // Comments and blank lines at the end of the block belong to what follows
                var keep = end
                while keep > index + 1, lines[keep - 1].hasPrefix("#") || lines[keep - 1].trimmingCharacters(in: .whitespaces).isEmpty { keep -= 1 }
                result += lines[keep..<end]
                index = end
            } else {
                result.append(lines[index])
                index += 1
            }
        }
        return result.joined(separator: "\n")
    }
}

extension ToolInfo {
    /// A page of the documentation of this version in the public repository.
    public static func documentation(_ page: String, anchor: String? = nil) -> String {
        "https://github.com/RyoHirota68/xcmutate/blob/v\(version)/docs/\(page)" + (anchor.map { "#\($0)" } ?? "")
    }
}
