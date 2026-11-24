import SwiftSyntax

/// The scheme of the stable keys, written into the files that hold keys (`xcmutate.accepted.json`, the JSON report)
/// so that keys of another scheme are recognized instead of silently matching nothing.
public enum MutantKeyScheme {
    /// The hash covers the syntactic path, the operator, the mutated text, the signatures of the enclosing
    /// declarations and the original text (see `StableKey`). A change of what it covers raises the number.
    public static let version = 2
}

/// A stable key for a mutant that does not depend on position (line numbers).
///
/// `file::path of the enclosing declaration::operator::hash`. The hash covers:
/// - the signatures of the enclosing declarations (parameter types, return type, generic and `where` clauses), so that
///   two overloads with the same labels have different keys whatever their order;
/// - the syntactic path from the enclosing declaration to the mutated node (node kinds and child positions). The
///   position of a statement among the top-level statements of a file, and of a member among the members of a
///   type, is left out: declarations added before it do not change the key;
/// - the operator;
/// - the original text of the mutated range and the mutated text (newlines, indentation after a newline and
///   comments normalized), so that the key changes when the expression that is rewritten changes.
///
/// It does not change when lines are added before the enclosing declaration, when blank or comment lines are added
/// or when the indentation changes (same idea as MutantKey in mizchi/mutator). It does change when the structure
/// of the declaration before the mutated node changes (a statement added earlier in the same function).
///
/// Two mutants with the same hash input (identical declarations in the two branches of an `#if`, say) are told
/// apart by order of appearance: the second gets the suffix `#2`.
enum StableKey {
    /// Version of the key scheme (`MutantKeyScheme.version`).
    static let version = MutantKeyScheme.version

    static func hashInput(signatures: String, syntaxPath: String, op: MutationOperator, original: String, replacement: String) -> String {
        ["v\(version)", signatures, syntaxPath, op.rawValue, original, replacement].joined(separator: "\u{1F}")
    }

    static func make(file: String, declPath: String, hashInput: String, op: MutationOperator) -> String {
        "\(file)::\(declPath)::\(op.rawValue)::\(String(fnv1a64(hashInput), radix: 16).leftPad(16))"
    }

    /// The original text of a mutated range as it goes into the hash: on one line, as `Flattener` writes it.
    static func normalized(_ text: String) -> String {
        if let flat = Flattener.flatten(text) { return flat }
        return text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }

    static func fnv1a64(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }
}

extension String {
    func leftPad(_ width: Int) -> String {
        count >= width ? self : String(repeating: "0", count: width - count) + self
    }
}

/// Path of the enclosing declaration (e.g. `Cart.total(of:)`, `Config.isLarge`, `<top>`).
enum DeclPath {
    static func of(_ node: Syntax) -> String {
        let components = components(of: node)
        return components.isEmpty ? "<top>" : components.joined(separator: ".")
    }

    /// The names of the declarations that enclose `node`, outermost first (`Cart`, `total(of:)`).
    static func components(of node: Syntax) -> [String] {
        var components: [String] = []
        var current: Syntax? = node.parent
        while let n = current {
            if let name = name(of: n) { components.append(name) }
            current = n.parent
        }
        return components.reversed()
    }

    /// What tells the enclosing declarations apart from others with the same name and labels: the types of the
    /// parameters, the effects, the return type and the generic and `where` clauses (outermost first).
    static func signatures(of node: Syntax) -> String {
        var components: [String] = []
        var current: Syntax? = node.parent
        while let n = current {
            if let signature = signature(of: n) { components.append(signature) }
            current = n.parent
        }
        return components.reversed().joined(separator: "|")
    }

    private static func tokens(_ node: (some SyntaxProtocol)?) -> String {
        guard let node else { return "" }
        return node.tokens(viewMode: .sourceAccurate).map(\.text).joined(separator: " ")
    }

    private static func parameterTypes(_ clause: FunctionParameterClauseSyntax) -> String {
        clause.parameters.map { "\($0.firstName.text):\(tokens($0.type))\($0.ellipsis == nil ? "" : "...")" }.joined(separator: ",")
    }

    private static func signature(of node: Syntax) -> String? {
        if let d = node.as(FunctionDeclSyntax.self) {
            return "\(tokens(d.genericParameterClause))(\(parameterTypes(d.signature.parameterClause)))\(tokens(d.signature.effectSpecifiers))->\(tokens(d.signature.returnClause?.type))\(tokens(d.genericWhereClause))"
        }
        if let d = node.as(InitializerDeclSyntax.self) {
            return "\(tokens(d.genericParameterClause))(\(parameterTypes(d.signature.parameterClause)))\(tokens(d.signature.effectSpecifiers))\(tokens(d.genericWhereClause))"
        }
        if let d = node.as(SubscriptDeclSyntax.self) {
            return "\(tokens(d.genericParameterClause))(\(parameterTypes(d.parameterClause)))->\(tokens(d.returnClause.type))\(tokens(d.genericWhereClause))"
        }
        if let d = node.as(ExtensionDeclSyntax.self) { return tokens(d.genericWhereClause) }
        if let d = node.as(StructDeclSyntax.self) { return tokens(d.genericParameterClause) + tokens(d.genericWhereClause) }
        if let d = node.as(ClassDeclSyntax.self) { return tokens(d.genericParameterClause) + tokens(d.genericWhereClause) }
        if let d = node.as(EnumDeclSyntax.self) { return tokens(d.genericParameterClause) + tokens(d.genericWhereClause) }
        if let d = node.as(ActorDeclSyntax.self) { return tokens(d.genericParameterClause) + tokens(d.genericWhereClause) }
        return nil
    }

    /// Whether the binding declares a member of a type or a variable at file level (and not a local variable).
    static func isDeclaration(_ binding: PatternBindingSyntax) -> Bool {
        guard let holder = binding.parent?.parent?.parent else { return false }
        if holder.is(MemberBlockItemSyntax.self) { return true }
        return holder.is(CodeBlockItemSyntax.self) && holder.parent?.parent?.is(SourceFileSyntax.self) == true
    }

    private static func name(of node: Syntax) -> String? {
        if let d = node.as(StructDeclSyntax.self) { return d.name.text }
        if let d = node.as(ClassDeclSyntax.self) { return d.name.text }
        if let d = node.as(EnumDeclSyntax.self) { return d.name.text }
        if let d = node.as(ActorDeclSyntax.self) { return d.name.text }
        if let d = node.as(ProtocolDeclSyntax.self) { return d.name.text }
        if let d = node.as(ExtensionDeclSyntax.self) { return "extension " + d.extendedType.trimmedDescription }
        if let d = node.as(FunctionDeclSyntax.self) {
            let labels = d.signature.parameterClause.parameters.map { "\($0.firstName.text):" }.joined()
            return "\(d.name.text)(\(labels))"
        }
        if let d = node.as(InitializerDeclSyntax.self) {
            let labels = d.signature.parameterClause.parameters.map { "\($0.firstName.text):" }.joined()
            return "init\(d.optionalMark?.text ?? "")(\(labels))"
        }
        if let d = node.as(SubscriptDeclSyntax.self) {
            let labels = d.parameterClause.parameters.map { "\($0.firstName.text):" }.joined()
            return "subscript(\(labels))"
        }
        if let d = node.as(AccessorDeclSyntax.self) { return d.accessorSpecifier.text }
        // A property or a global; a `let` inside a function body is a statement of that function, not a declaration
        // of its own (reports group mutants by declaration, and would show the function once per local variable)
        if let d = node.as(PatternBindingSyntax.self) { return isDeclaration(d) ? d.pattern.trimmedDescription : nil }
        if let d = node.as(MacroExpansionDeclSyntax.self) { return "#" + d.macroName.text }
        return nil
    }
}

/// Syntactic path from the enclosing declaration to the target node (node kinds and child positions).
enum SyntaxPath {
    static func of(_ node: Syntax) -> String {
        var components: [String] = []
        var current: Syntax = node
        while let parent = current.parent {
            let index = parent.children(viewMode: .sourceAccurate).firstIndex { $0.id == current.id }
                .map { parent.children(viewMode: .sourceAccurate).distance(from: parent.children(viewMode: .sourceAccurate).startIndex, to: $0) } ?? -1
            // Where a statement stands among the top-level statements of the file, or a member among the members of
            // a type, is not part of the path: adding a declaration before it must not change the key
            let unordered = (current.is(CodeBlockItemSyntax.self) && parent.parent?.is(SourceFileSyntax.self) == true) || current.is(MemberBlockItemSyntax.self)
            components.append(unordered ? "\(current.kind)" : "\(current.kind)#\(index)")
            if isDeclBoundary(parent) { break }
            current = parent
        }
        return components.reversed().joined(separator: "/")
    }

    private static func isDeclBoundary(_ node: Syntax) -> Bool {
        node.is(FunctionDeclSyntax.self) || node.is(InitializerDeclSyntax.self) || node.is(AccessorDeclSyntax.self)
            || node.is(SubscriptDeclSyntax.self) || node.as(PatternBindingSyntax.self).map(DeclPath.isDeclaration) == true || node.is(DeinitializerDeclSyntax.self)
            || node.is(SourceFileSyntax.self)
    }
}
