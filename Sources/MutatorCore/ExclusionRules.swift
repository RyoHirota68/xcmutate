import SwiftSyntax

/// Rules for positions where switches are not embedded (docs/how-it-works.md).
enum ExclusionRules {
    static let inlinableAttributes: Set<String> = ["inlinable", "_alwaysEmitIntoClient", "_transparent", "backDeployed"]
    static let publicModifiers: Set<String> = ["public", "open", "package"]

    static func reason(for candidate: Candidate, options: GeneratorOptions) -> IgnoreReason? {
        let node = candidate.node
        if candidate.op == .booleanLiteral, let reason = literalReason(node, options: options) {
            return reason
        }

        // Wrapping the replaced range in parentheses would cut an optional chain
        if breaksOptionalChain(regionNode(for: candidate)) {
            return .optionalChain
        }

        var child: Syntax = node
        var current = node.parent
        while let ancestor = current {
            if let reason = ancestorReason(ancestor, child: child, options: options) {
                return reason
            }
            child = ancestor
            current = ancestor.parent
        }
        return nil
    }

    /// The syntax tree node corresponding to the candidate's range (the outermost node whose range matches).
    static func regionNode(for candidate: Candidate) -> Syntax {
        var node = candidate.node
        while let parent = node.parent, parent.trimmedByteRange == candidate.region, !parent.is(CodeBlockItemSyntax.self) {
            node = parent
        }
        return node
    }

    /// Whether wrapping `node` in parentheses changes the meaning of an optional chain.
    /// This is the case when `node` is in the middle of a postfix chain (member access, call, subscript, `!`, `?`) and
    /// the `?` of that chain is inside `node` (`user?.name.lowercased()` in `user?.name.lowercased().hasPrefix("a")`).
    static func breaksOptionalChain(_ node: Syntax) -> Bool {
        guard let parent = node.parent, continuesPostfixChain(parent: parent, child: node) else { return false }
        return containsChainOptional(node)
    }

    static func continuesPostfixChain(parent: Syntax, child: Syntax) -> Bool {
        if let m = parent.as(MemberAccessExprSyntax.self) { return m.base?.id == child.id }
        if let c = parent.as(FunctionCallExprSyntax.self) { return c.calledExpression.id == child.id }
        if let s = parent.as(SubscriptCallExprSyntax.self) { return s.calledExpression.id == child.id }
        if parent.is(ForceUnwrapExprSyntax.self) || parent.is(OptionalChainingExprSyntax.self) || parent.is(PostfixOperatorExprSyntax.self) {
            return true
        }
        return false
    }

    /// Whether there is a `?` (OptionalChainingExpr) along the postfix chain.
    static func containsChainOptional(_ node: Syntax) -> Bool {
        var current: Syntax? = node
        while let n = current {
            if n.is(OptionalChainingExprSyntax.self) { return true }
            if let m = n.as(MemberAccessExprSyntax.self) { current = m.base.map(Syntax.init); continue }
            if let c = n.as(FunctionCallExprSyntax.self) { current = Syntax(c.calledExpression); continue }
            if let s = n.as(SubscriptCallExprSyntax.self) { current = Syntax(s.calledExpression); continue }
            if let f = n.as(ForceUnwrapExprSyntax.self) { current = Syntax(f.expression); continue }
            if let p = n.as(PostfixOperatorExprSyntax.self) { current = Syntax(p.expression); continue }
            return false
        }
        return false
    }

    /// Exclusions specific to boolean literals.
    private static func literalReason(_ node: Syntax, options: GeneratorOptions) -> IgnoreReason? {
        // Arid arguments such as `animated: true`.
        if let labeled = node.parent?.as(LabeledExprSyntax.self), let label = labeled.label?.text,
           options.aridArgumentLabels.contains(label) {
            return .aridArgument
        }
        // The condition itself is a literal, as in `while true` / `if true`.
        // Rewriting it changes the compiler's reachability and definite-initialization analysis and can break the build.
        if let element = node.parent?.as(ConditionElementSyntax.self),
           case let .expression(expr) = element.condition, expr.id == node.id {
            return .constantCondition
        }
        if let repeatStmt = node.parent?.as(RepeatStmtSyntax.self), repeatStmt.condition.id == node.id {
            return .constantCondition
        }
        return nil
    }

    private static func ancestorReason(_ ancestor: Syntax, child: Syntax, options: GeneratorOptions) -> IgnoreReason? {
        switch ancestor.kind {
        case .ifConfigClause:
            if let clause = ancestor.as(IfConfigClauseSyntax.self), let condition = clause.condition,
               condition.id == child.id {
                return .ifConfigCondition
            }
            if let clause = ancestor.as(IfConfigClauseSyntax.self), let platform = options.targetPlatform,
               IfConfigEvaluator.isCompiled(clause, for: platform) == false {
                return .inactiveIfConfig
            }
        case .macroExpansionExpr, .macroExpansionDecl:
            return .macroExpansion
        case .attribute:
            return .attributeArgument
        case .genericWhereClause, .genericParameterClause, .genericArgumentClause, .inheritanceClause:
            return .typeContext
        case .enumCaseElement, .enumCaseParameter:
            return .enumCase
        case .keyPathExpr:
            return .keyPath
        case .inOutExpr:
            return .inoutArgument
        case .deinitializerDecl:
            return .deinitializer
        case .precedenceGroupDecl, .operatorDecl:
            return .operatorDeclaration
        case .sequenceExpr:
            // A sequence that remains after folding is one whose precedence could not be determined.
            return .unfoldableOperators
        case .functionCallExpr:
            if let call = ancestor.as(FunctionCallExprSyntax.self), isAridCall(call, options: options) {
                return .aridCall
            }
        case .initializerClause:
            if let reason = initializerReason(ancestor.cast(InitializerClauseSyntax.self)) {
                return reason
            }
        default:
            break
        }

        if ancestor.is(PatternSyntax.self) {
            return .pattern
        }
        if ancestor.is(TypeSyntax.self) {
            return .typeContext
        }
        if ancestor.is(DeclSyntax.self), isEmittedIntoClients(ancestor) {
            return .inlinableBody
        }
        return nil
    }

    /// Places among default arguments and property initial values where the helper (fileprivate) cannot be referenced.
    private static func initializerReason(_ clause: InitializerClauseSyntax) -> IgnoreReason? {
        guard let parent = clause.parent else { return nil }
        if parent.is(FunctionParameterSyntax.self) {
            // Default arguments of public (and similar) functions are inlined at the call site, so they cannot reference fileprivate.
            var current = parent.parent
            while let node = current {
                if node.is(DeclSyntax.self) {
                    if hasModifier(node, in: publicModifiers) || hasAttribute(node, in: inlinableAttributes.union(["usableFromInline"])) {
                        return .publicDefaultArgument
                    }
                }
                current = node.parent
            }
            return nil
        }
        if parent.is(PatternBindingSyntax.self) {
            // Initial values of stored properties of @frozen types are also exposed externally.
            var current = parent.parent
            while let node = current {
                if node.is(DeclSyntax.self), hasAttribute(node, in: ["frozen", "usableFromInline"]) {
                    return .frozenPropertyInitializer
                }
                current = node.parent
            }
        }
        return nil
    }

    /// Whether the body of the declaration is compiled into other modules, where the file-private helper cannot be named:
    /// `@inlinable`, `@_alwaysEmitIntoClient`, `@_transparent`, `@backDeployed`, `@export(implementation)` (the new
    /// spelling of `@_alwaysEmitIntoClient`), and `@inline(always)` on a declaration that other modules can see
    /// (it implies `@inlinable` there; `@inline(__always)` and declarations that are not public are not affected).
    static func isEmittedIntoClients(_ node: Syntax) -> Bool {
        guard let withAttributes = node.asProtocol(WithAttributesSyntax.self) else { return false }
        for element in withAttributes.attributes {
            guard case let .attribute(attribute) = element, let name = attribute.attributeName.as(IdentifierTypeSyntax.self)?.name.text else { continue }
            if inlinableAttributes.contains(name) { return true }
            let arguments = attribute.arguments?.trimmedDescription.filter { !$0.isWhitespace } ?? ""
            if name == "export", arguments == "implementation" { return true }
            if name == "inline", arguments == "always", isVisibleToOtherModules(node) { return true }
        }
        return false
    }

    /// `public`, `open` or `package`, on the declaration itself or on the extension it is a member of.
    static func isVisibleToOtherModules(_ node: Syntax) -> Bool {
        if hasModifier(node, in: publicModifiers) { return true }
        var current = node.parent
        while let ancestor = current {
            if ancestor.is(ExtensionDeclSyntax.self) { return hasModifier(ancestor, in: publicModifiers) }
            if ancestor.is(DeclSyntax.self) { return false }
            current = ancestor.parent
        }
        return false
    }

    static func hasAttribute(_ node: Syntax, in names: Set<String>) -> Bool {
        guard let withAttributes = node.asProtocol(WithAttributesSyntax.self) else { return false }
        for element in withAttributes.attributes {
            if case let .attribute(attribute) = element,
               let name = attribute.attributeName.as(IdentifierTypeSyntax.self)?.name.text,
               names.contains(name) {
                return true
            }
        }
        return false
    }

    static func hasModifier(_ node: Syntax, in names: Set<String>) -> Bool {
        guard let withModifiers = node.asProtocol(WithModifiersSyntax.self) else { return false }
        return withModifiers.modifiers.contains { names.contains($0.name.text) }
    }

    /// Calls for which no meaningful test can be written even when they are rewritten, such as logging and assert-like calls.
    static func isAridCall(_ call: FunctionCallExprSyntax, options: GeneratorOptions) -> Bool {
        let callee = call.calledExpression
        if !options.aridCallPatterns.isEmpty {
            let text = callee.trimmedDescription
            let lastName = callee.as(MemberAccessExprSyntax.self)?.declName.baseName.text
                ?? callee.as(DeclReferenceExprSyntax.self)?.baseName.text
            for pattern in options.aridCallPatterns where !pattern.isEmpty {
                if text == pattern || text.hasPrefix(pattern + ".") || text.hasPrefix(pattern + "(") || lastName == pattern {
                    return true
                }
            }
        }
        if let ref = callee.as(DeclReferenceExprSyntax.self) {
            return options.aridCallNames.contains(ref.baseName.text)
        }
        if let member = callee.as(MemberAccessExprSyntax.self) {
            let name = member.declName.baseName.text
            if options.aridCallNames.contains(name) { return true }
            if GeneratorOptions.loggerMethodNames.contains(name), let base = member.base,
               base.trimmedDescription.lowercased().contains("log") {
                return true
            }
        }
        return false
    }
}

/// `excludeDeclarations` of the config file: declarations whose bodies are not mutated, chosen by name.
///
/// Meant for code that exists only for the tests and is compiled into debug builds: `resetForTesting()`,
/// `_setClockForTesting(_:)`. The tests call such code to prepare a state, not to check it, so its mutants are
/// reached, mostly survive or change nothing that a test looks at, and say nothing about the product. Which names
/// mean "only for the tests" is a convention of the project, so nothing is excluded by default.
public enum DeclarationPatterns {
    /// The name of a declaration as it is compared: without the parameter list (`total(of:)` → `total`).
    static func baseName(_ component: String) -> String {
        String(component.prefix { $0 != "(" })
    }

    /// Whether `name` matches `pattern`; `*` stands for any text (also none), everything else for itself.
    public static func matches(_ name: String, pattern: String) -> Bool {
        let parts = pattern.split(separator: "*", omittingEmptySubsequences: false).map(String.init)
        guard parts.count > 1 else { return name == pattern }
        var rest = Substring(name)
        for (index, part) in parts.enumerated() {
            if index == 0 {
                guard rest.hasPrefix(part) else { return false }
                rest = rest.dropFirst(part.count)
            } else if index == parts.count - 1 {
                return rest.hasSuffix(part)
            } else if !part.isEmpty {
                guard let found = rest.firstRange(of: part) else { return false }
                rest = rest[found.upperBound...]
            }
        }
        return true
    }

    /// Whether one of the enclosing declarations (`DeclPath.components`) is named by one of the patterns.
    public static func excludes(_ components: [String], patterns: [String]) -> Bool {
        guard !patterns.isEmpty else { return false }
        return components.contains { component in
            let name = baseName(component)
            return patterns.contains { !$0.isEmpty && matches(name, pattern: $0) }
        }
    }
}
