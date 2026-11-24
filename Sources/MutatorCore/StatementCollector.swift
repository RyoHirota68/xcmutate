import SwiftSyntax

/// Collects candidates for side-effect statement removal (function-call statements whose return value is discarded).
///
/// Rules (the statement level; docs/how-it-works.md):
/// - An expression statement that is a function call (including with `try` / `await`) or `_ = call`
/// - Inside the body of a function, initializer, accessor or subscript. Closure bodies and the file's top level are
///   not targeted (not even as candidates), because whether a closure is a result builder cannot be determined from syntax
/// - Other exclusions (result builder, implicit return, non-returning call, init delegation, arid, synchronization, the last
///   statement of a guard's else clause) are kept as exclusions with a reason (`ExclusionRules.statementReason`)
final class StatementCollector: SyntaxVisitor {
    let options: GeneratorOptions
    var candidates: [Candidate] = []

    init(options: GeneratorOptions) {
        self.options = options
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: CodeBlockItemSyntax) -> SyntaxVisitorContinueKind {
        guard options.operators.contains(.sideEffectRemoval),
              let expr = node.item.as(ExprSyntax.self),
              Self.discardedCall(in: expr) != nil,
              Self.bodyOwner(of: node) != nil else {
            return .visitChildren
        }
        let range = expr.trimmedByteRange
        let text = expr.trimmedDescription
        candidates.append(Candidate(
            op: .sideEffectRemoval, node: Syntax(node), region: range, point: range,
            edits: [Edit(range: range, text: "")],
            original: text, replacement: ""))
        return .visitChildren
    }

    /// If the statement's expression is a "function call whose return value is discarded", returns that call.
    static func discardedCall(in expr: ExprSyntax) -> FunctionCallExprSyntax? {
        var current = expr
        if let infix = current.as(InfixOperatorExprSyntax.self), infix.operator.is(AssignmentExprSyntax.self) {
            guard infix.leftOperand.is(DiscardAssignmentExprSyntax.self) else { return nil }
            current = infix.rightOperand
        }
        while true {
            if let tryExpr = current.as(TryExprSyntax.self) {
                current = tryExpr.expression
            } else if let awaitExpr = current.as(AwaitExprSyntax.self) {
                current = awaitExpr.expression
            } else {
                break
            }
        }
        return current.as(FunctionCallExprSyntax.self)
    }

    /// The declaration that has the statement in its body (function, initializer, accessor, etc.). `nil` for closures and the top level.
    static func bodyOwner(of node: CodeBlockItemSyntax) -> Syntax? {
        var current = node.parent
        while let n = current {
            switch n.kind {
            case .closureExpr, .sourceFile, .macroExpansionExpr, .macroExpansionDecl:
                return nil
            case .functionDecl, .initializerDecl, .deinitializerDecl, .accessorDecl, .subscriptDecl:
                return n
            case .patternBinding:
                // `var x: T { … }` (get-only shorthand)
                return n
            default:
                current = n.parent
            }
        }
        return nil
    }
}

extension ExclusionRules {
    /// Exclusion reasons specific to statement removal.
    static func statementReason(for candidate: Candidate, options: GeneratorOptions) -> IgnoreReason? {
        guard let item = candidate.node.as(CodeBlockItemSyntax.self),
              let expr = item.item.as(ExprSyntax.self),
              let call = StatementCollector.discardedCall(in: expr) else {
            return nil
        }
        // A statement in a closure (`closure-statement-removal`) has no declaration as its owner; the rules about
        // the body of a declaration do not apply to it, the others do
        let owner = StatementCollector.bodyOwner(of: item)
        guard owner != nil || candidate.op == .closureStatementRemoval else { return nil }

        // Inside a result builder (a declaration with an attribute named `*Builder`, or `var body: some View`)
        if let owner, isResultBuilderBody(owner, options: options) {
            return .resultBuilder
        }

        let name = calleeName(call)
        if let name, options.neverReturningNames.contains(name) {
            return .neverReturning
        }

        // The statement that a value-returning body ends with on some path. Without it that path would fall off the
        // end of the body, so the body would not compile even with all mutants off:
        // - the body is one `if` / `switch` expression and the statement is the value of a branch
        //   (`var title: String { switch self { case .home: loc("Home") … } }`);
        // - otherwise the call does not return (a function declared `-> Never` in another module, or under a name
        //   that is not in the lists), or the original would not compile either.
        if let owner, returnsValue(owner), let bodyIsOneStatement = tailPosition(of: item, owner: owner) {
            return bodyIsOneStatement ? .implicitReturn : .neverReturning
        }
        // A closure whose body is one `if` / `switch` expression: the statement may be the closure's value
        if owner == nil, let closure = ReturnAndClosureOperatorCollector.enclosingClosure(of: item), closure.statements.count == 1,
           item.parent?.id != closure.statements.id, tailPosition(of: item, body: closure.statements) != nil {
            return .implicitReturn
        }

        // The last statement (the value of that branch) of a branch of an if / switch expression such as `let x = if c { f() } else { 0 }`
        if isValueOfControlFlowExpression(item) {
            return .implicitReturn
        }

        // The single expression of a value-returning function or getter whose body is one expression (nested blocks such as defer are not covered)
        if let owner, let list = item.parent?.as(CodeBlockItemListSyntax.self), list.count == 1, returnsValue(owner),
           isDirectBody(list, of: owner) {
            return .implicitReturn
        }

        if let member = call.calledExpression.as(MemberAccessExprSyntax.self), member.declName.baseName.text == "init" {
            return .initializerDelegation
        }

        if isAridCall(call, options: options) {
            return .aridCall
        }
        if let member = call.calledExpression.as(MemberAccessExprSyntax.self) {
            let method = member.declName.baseName.text
            if options.aridStatementNames.contains(method) { return .aridCall }
            if options.synchronizationMethodNames.contains(method) { return .synchronization }
        }

        // The last statement of a guard's else clause (needed to leave the scope)
        if let list = item.parent?.as(CodeBlockItemListSyntax.self), list.last?.id == item.id,
           list.parent?.as(CodeBlockSyntax.self)?.parent?.is(GuardStmtSyntax.self) == true {
            return .guardElse
        }
        return nil
    }

    /// Whether the statement is the last statement of a branch of an if / switch expression used as a value.
    static func isValueOfControlFlowExpression(_ item: CodeBlockItemSyntax) -> Bool {
        guard let list = item.parent?.as(CodeBlockItemListSyntax.self), list.last?.id == item.id else { return false }
        var container: Syntax?
        if let block = list.parent?.as(CodeBlockSyntax.self), block.parent?.is(IfExprSyntax.self) == true {
            container = block.parent
        } else if list.parent?.is(SwitchCaseSyntax.self) == true {
            container = list.parent?.parent?.parent  // SwitchCase → SwitchCaseList → SwitchExpr
        }
        // A chain of `else if` goes up to the outermost if
        while let c = container, let parent = c.parent, parent.is(IfExprSyntax.self) { container = parent }
        guard let expr = container, let parent = expr.parent else { return false }
        // An if / switch used as a statement (directly under a CodeBlockItem, or an ExpressionStmt) is not a value
        if parent.is(ExpressionStmtSyntax.self) || parent.is(CodeBlockItemSyntax.self) { return false }
        return true
    }

    /// Whether control reaches the end of the body right after `item`: it is the last statement of the body, or the
    /// last statement of a branch (`if` / `else`, `case`, `do`, `catch`) of a statement that is itself in that
    /// position. Loops, `defer`, `guard` and nested functions and closures end the search.
    /// - Returns: nil if `item` is not in that position; otherwise whether the body consists of one statement.
    static func tailPosition(of item: CodeBlockItemSyntax, owner: Syntax) -> Bool? {
        var current = item
        while true {
            guard let list = current.parent?.as(CodeBlockItemListSyntax.self), list.last?.id == current.id else { return nil }
            if isDirectBody(list, of: owner) { return list.count == 1 }
            guard let holder = branchHolder(of: list) else { return nil }
            current = holder
        }
    }

    static func tailPosition(of item: CodeBlockItemSyntax, body: CodeBlockItemListSyntax) -> Bool? {
        var current = item
        while true {
            guard let list = current.parent?.as(CodeBlockItemListSyntax.self), list.last?.id == current.id else { return nil }
            if list.id == body.id { return true }
            guard let holder = branchHolder(of: list) else { return nil }
            current = holder
        }
    }

    /// The statement of which `list` is a branch, when that statement is an `if`, `switch` or `do` written as a statement.
    private static func branchHolder(of list: CodeBlockItemListSyntax) -> CodeBlockItemSyntax? {
        var container: Syntax?
        if let block = list.parent?.as(CodeBlockSyntax.self), let parent = block.parent {
            if parent.is(IfExprSyntax.self) || parent.is(DoStmtSyntax.self) {
                container = parent
            } else if parent.is(CatchClauseSyntax.self) {
                container = parent.parent?.parent  // CatchClause → CatchClauseList → DoStmt
            }
        } else if list.parent?.is(SwitchCaseSyntax.self) == true {
            container = list.parent?.parent?.parent  // SwitchCase → SwitchCaseList → SwitchExpr
        }
        // A chain of `else if` goes up to the outermost if
        while let c = container, let parent = c.parent, parent.is(IfExprSyntax.self) { container = parent }
        guard var node = container?.parent else { return nil }
        if node.is(ExpressionStmtSyntax.self), let parent = node.parent { node = parent }
        return node.as(CodeBlockItemSyntax.self)
    }

    static func calleeName(_ call: FunctionCallExprSyntax) -> String? {
        if let ref = call.calledExpression.as(DeclReferenceExprSyntax.self) { return ref.baseName.text }
        if let member = call.calledExpression.as(MemberAccessExprSyntax.self) { return member.declName.baseName.text }
        return nil
    }

    /// Whether the statement list is the declaration's body itself (not a nested block).
    static func isDirectBody(_ list: CodeBlockItemListSyntax, of owner: Syntax) -> Bool {
        guard let parent = list.parent else { return false }
        if parent.is(CodeBlockSyntax.self) { return parent.parent?.id == owner.id }
        // The `var x: T { expr }` shorthand
        if parent.is(AccessorBlockSyntax.self) { return parent.parent?.id == owner.id }
        return false
    }

    static func isResultBuilderBody(_ owner: Syntax, options: GeneratorOptions) -> Bool {
        var current: Syntax? = owner
        while let n = current {
            // Stop at a type declaration (the methods of a `@resultBuilder` type itself are not builder bodies)
            if n.is(StructDeclSyntax.self) || n.is(ClassDeclSyntax.self) || n.is(EnumDeclSyntax.self)
                || n.is(ActorDeclSyntax.self) || n.is(ExtensionDeclSyntax.self) || n.is(ProtocolDeclSyntax.self) {
                return false
            }
            if n.is(DeclSyntax.self) {
                if let withAttributes = n.asProtocol(WithAttributesSyntax.self) {
                    for element in withAttributes.attributes {
                        if case let .attribute(attribute) = element,
                           let attrName = attribute.attributeName.as(IdentifierTypeSyntax.self)?.name.text,
                           attrName.hasSuffix("Builder") || options.resultBuilderNames.contains(attrName) {
                            return true
                        }
                    }
                }
                if let variable = n.as(VariableDeclSyntax.self) {
                    for binding in variable.bindings where binding.pattern.trimmedDescription == "body" {
                        if let type = binding.typeAnnotation?.type.trimmedDescription, type.hasPrefix("some ") {
                            return true
                        }
                    }
                }
            }
            current = n.parent
        }
        return false
    }

    /// Whether the body returns a value (i.e. could be an implicit return).
    static func returnsValue(_ owner: Syntax) -> Bool {
        if let function = owner.as(FunctionDeclSyntax.self) {
            guard let type = function.signature.returnClause?.type.trimmedDescription else { return false }
            return !["Void", "()", "Swift.Void"].contains(type)
        }
        if let accessor = owner.as(AccessorDeclSyntax.self) {
            return accessor.accessorSpecifier.tokenKind == .keyword(.get)
        }
        if owner.is(PatternBindingSyntax.self) || owner.is(SubscriptDeclSyntax.self) {
            return true
        }
        return false
    }
}

/// The line range of the declaration enclosing a mutant.
enum ScopeFinder {
    static func of(_ node: Syntax, converter: SourceLocationConverter) -> MutantScope {
        // Prefer functions, initializers and the like. If none is found, use the outermost property declaration (type member or global variable).
        var current: Syntax? = node.parent
        var scopeNode: Syntax?
        var variableFallback: Syntax?
        while let n = current {
            switch n.kind {
            case .functionDecl, .initializerDecl, .deinitializerDecl, .subscriptDecl, .macroExpansionDecl:
                scopeNode = n
            case .variableDecl:
                variableFallback = n
            default:
                break
            }
            if scopeNode != nil { break }
            current = n.parent
        }
        scopeNode = scopeNode ?? variableFallback
        let target = scopeNode ?? topLevelItem(of: node) ?? node
        let start = converter.location(for: target.positionAfterSkippingLeadingTrivia).line
        let end = converter.location(for: target.endPositionBeforeTrailingTrivia).line
        return MutantScope(id: DeclPath.of(node), lines: LineSpan(start: start, end: end))
    }

    private static func topLevelItem(of node: Syntax) -> Syntax? {
        var current: Syntax? = node
        while let n = current {
            if n.parent?.parent?.is(SourceFileSyntax.self) == true { return n }
            current = n.parent
        }
        return nil
    }
}
