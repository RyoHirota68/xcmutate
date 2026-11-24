import SwiftSyntax

/// Three rewrites whose position needs more care than that of the other operators.
///
/// - `return-case`: `return .failure(error)` → another value that the same function returns. Only values that need
///   nothing from the place where they were written are used (a case without arguments, or a case whose arguments are
///   literals and such cases), so the replacement compiles wherever in the function it is put.
/// - `implicit-return-value`: the single expression of a body that returns a value → `nil`, empty or 0 by the declared
///   type. Not made when the expression is a literal (a constant accessor), when the type is not one of the known
///   ones, or in a result builder.
/// - `closure-statement-removal`: a call statement in a closure, when syntax shows that the closure is not a result
///   builder: it contains a statement that the result-builder transform does not accept (`return`, `guard`, `while`,
///   `repeat`, `defer`, `break`, `continue`), or it is an argument of a call that is known to take a plain closure
///   (`forEach`, `DispatchQueue.async`, …). A closure of one statement is mutated only for calls whose closure
///   returns nothing, because that statement could be the closure's value otherwise.
final class ReturnAndClosureOperatorCollector: SyntaxVisitor {
    let options: GeneratorOptions
    var candidates: [Candidate] = []

    init(options: GeneratorOptions) {
        self.options = options
        super.init(viewMode: .sourceAccurate)
    }

    // MARK: return-case

    override func visit(_ node: ReturnStmtSyntax) -> SyntaxVisitorContinueKind {
        guard options.operators.contains(.returnCase), var expr = node.expression,
              let owner = ExtendedOperatorCollector.returningDecl(of: Syntax(node)) else { return .visitChildren }
        while true {
            if let t = expr.as(TryExprSyntax.self) { expr = t.expression } else if let a = expr.as(AwaitExprSyntax.self) { expr = a.expression } else { break }
        }
        guard Self.implicitMemberCall(expr) != nil else { return .visitChildren }
        let text = expr.trimmedDescription
        let own = text.filter { !$0.isWhitespace }
        let range = expr.trimmedByteRange
        let alternatives = Self.returnedSimpleValues(in: owner).filter { $0.filter { !$0.isWhitespace } != own }
        for replacement in alternatives.prefix(options.maxReturnAlternatives) {
            candidates.append(Candidate(
                op: .returnCase, node: Syntax(expr), region: range, point: range,
                edits: [Edit(range: range, text: replacement)], original: text, replacement: replacement))
        }
        return .visitChildren
    }

    /// If this is a call of an implicit member (`.failure(error)`), the name of the member. Not `.init(…)`, and not a
    /// call with a trailing closure.
    static func implicitMemberCall(_ expr: ExprSyntax) -> String? {
        guard let call = expr.as(FunctionCallExprSyntax.self), call.trailingClosure == nil, call.additionalTrailingClosures.isEmpty,
              let member = call.calledExpression.as(MemberAccessExprSyntax.self), member.base == nil,
              member.declName.baseName.text != "init" else { return nil }
        return member.declName.baseName.text
    }

    /// A value that reads the same anywhere: a literal, an implicit member, or an implicit-member call of such values.
    static func isContextFree(_ expr: ExprSyntax) -> Bool {
        if ExtendedOperatorCollector.isSimpleValue(expr) { return true }
        if let prefix = expr.as(PrefixOperatorExprSyntax.self), prefix.operator.text == "-" {
            return prefix.expression.is(IntegerLiteralExprSyntax.self) || prefix.expression.is(FloatLiteralExprSyntax.self)
        }
        if let array = expr.as(ArrayExprSyntax.self) { return array.elements.allSatisfy { isContextFree($0.expression) } }
        if let dictionary = expr.as(DictionaryExprSyntax.self), case .colon = dictionary.content { return true }
        if implicitMemberCall(expr) != nil, let call = expr.as(FunctionCallExprSyntax.self) {
            return call.arguments.allSatisfy { isContextFree($0.expression) }
        }
        return false
    }

    /// The context-free values that the declaration returns (return expressions and their ternary branches; nested
    /// closures and functions left out), in order of appearance.
    static func returnedSimpleValues(in owner: Syntax) -> [String] {
        final class Finder: SyntaxVisitor {
            var values: [String] = []
            let root: Syntax
            init(root: Syntax) { self.root = root; super.init(viewMode: .sourceAccurate) }
            override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
            override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind { node.id == root.id ? .visitChildren : .skipChildren }
            override func visit(_ node: ReturnStmtSyntax) -> SyntaxVisitorContinueKind {
                guard var expr = node.expression else { return .skipChildren }
                while true {
                    if let t = expr.as(TryExprSyntax.self) { expr = t.expression } else if let a = expr.as(AwaitExprSyntax.self) { expr = a.expression } else { break }
                }
                var exprs = [expr]
                if let ternary = expr.as(TernaryExprSyntax.self) { exprs = [ternary.thenExpression, ternary.elseExpression] }
                for e in exprs {
                    let isMember = ExtendedOperatorCollector.implicitMember(e) != nil
                    let isCall = ReturnAndClosureOperatorCollector.implicitMemberCall(e) != nil && ReturnAndClosureOperatorCollector.isContextFree(e)
                    guard isMember || isCall else { continue }
                    let text = e.trimmedDescription
                    if !values.contains(text) { values.append(text) }
                }
                return .skipChildren
            }
        }
        let finder = Finder(root: owner)
        finder.walk(owner)
        return finder.values
    }

    // MARK: implicit-return-value

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        if let statements = node.body?.statements {
            implicitValue(statements, type: node.signature.returnClause?.type.trimmedDescription, owner: Syntax(node))
        }
        return .visitChildren
    }

    override func visit(_ node: PatternBindingSyntax) -> SyntaxVisitorContinueKind {
        if case let .getter(statements)? = node.accessorBlock?.accessors {
            implicitValue(statements, type: node.typeAnnotation?.type.trimmedDescription, owner: Syntax(node))
        }
        return .visitChildren
    }

    override func visit(_ node: SubscriptDeclSyntax) -> SyntaxVisitorContinueKind {
        if case let .getter(statements)? = node.accessorBlock?.accessors {
            implicitValue(statements, type: node.returnClause.type.trimmedDescription, owner: Syntax(node))
        }
        return .visitChildren
    }

    override func visit(_ node: AccessorDeclSyntax) -> SyntaxVisitorContinueKind {
        if node.accessorSpecifier.tokenKind == .keyword(.get), let statements = node.body?.statements {
            var current = node.parent
            while let n = current, !n.is(PatternBindingSyntax.self), !n.is(SubscriptDeclSyntax.self) { current = n.parent }
            let type = current?.as(PatternBindingSyntax.self)?.typeAnnotation?.type.trimmedDescription
                ?? current?.as(SubscriptDeclSyntax.self)?.returnClause.type.trimmedDescription
            implicitValue(statements, type: type, owner: Syntax(node))
        }
        return .visitChildren
    }

    override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
        // Only a closure that declares its return type: `{ (x: Int) -> Int? in table[x] }`
        if let type = node.signature?.returnClause?.type.trimmedDescription {
            implicitValue(node.statements, type: type, owner: nil)
        }
        return .visitChildren
    }

    private func implicitValue(_ statements: CodeBlockItemListSyntax, type: String?, owner: Syntax?) {
        guard options.operators.contains(.implicitReturnValue), let type, statements.count == 1,
              var expr = statements.first?.item.as(ExprSyntax.self) else { return }
        if let owner, ExclusionRules.isResultBuilderBody(owner, options: options) { return }
        // `try f()` / `await f()`: the inside is replaced (as for `return`). `try? f()` is left to `try-optional-nil`,
        // which makes the same change, and `try! f()` is replaced as a whole
        while true {
            if let t = expr.as(TryExprSyntax.self) {
                if t.questionOrExclamationMark?.tokenKind == .postfixQuestionMark { return }
                if t.questionOrExclamationMark != nil { break }
                expr = t.expression
            } else if let a = expr.as(AwaitExprSyntax.self) {
                expr = a.expression
            } else {
                break
            }
        }
        // An `if` / `switch` expression cannot sit inside a ternary branch; a literal is a constant, not logic
        if expr.is(SwitchExprSyntax.self) || expr.is(IfExprSyntax.self) || Self.isLiteral(expr) { return }
        let text = expr.trimmedDescription
        if text == "self" || text == "Self()" { return }
        guard let value = ExtendedOperatorCollector.defaultValue(forType: type), value != text else { return }
        let range = expr.trimmedByteRange
        candidates.append(Candidate(
            op: .implicitReturnValue, node: Syntax(expr), region: range, point: range,
            edits: [Edit(range: range, text: value)], original: text, replacement: value))
    }

    static func isLiteral(_ expr: ExprSyntax) -> Bool {
        if ExtendedOperatorCollector.isSimpleValue(expr), ExtendedOperatorCollector.implicitMember(expr) == nil { return true }
        if let prefix = expr.as(PrefixOperatorExprSyntax.self), prefix.operator.text == "-" { return isLiteral(prefix.expression) }
        if let array = expr.as(ArrayExprSyntax.self) { return array.elements.allSatisfy { isLiteral($0.expression) } }
        if let dictionary = expr.as(DictionaryExprSyntax.self) {
            if case let .elements(elements) = dictionary.content { return elements.allSatisfy { isLiteral($0.key) && isLiteral($0.value) } }
            return true
        }
        return false
    }

    // MARK: closure-statement-removal

    override func visit(_ node: CodeBlockItemSyntax) -> SyntaxVisitorContinueKind {
        guard options.operators.contains(.closureStatementRemoval),
              let expr = node.item.as(ExprSyntax.self),
              StatementCollector.discardedCall(in: expr) != nil,
              let closure = Self.enclosingClosure(of: node),
              Self.isKnownPlainClosure(closure, options: options) else {
            return .visitChildren
        }
        let range = expr.trimmedByteRange
        candidates.append(Candidate(
            op: .closureStatementRemoval, node: Syntax(node), region: range, point: range,
            edits: [Edit(range: range, text: "")],
            original: expr.trimmedDescription, replacement: ""))
        return .visitChildren
    }

    /// The closure whose body has the statement (directly or in nested blocks); nil when a declaration, a macro or the
    /// file comes first.
    static func enclosingClosure(of node: CodeBlockItemSyntax) -> ClosureExprSyntax? {
        var current = node.parent
        while let n = current {
            switch n.kind {
            case .closureExpr:
                return n.as(ClosureExprSyntax.self)
            case .sourceFile, .macroExpansionExpr, .macroExpansionDecl, .functionDecl, .initializerDecl, .deinitializerDecl,
                 .accessorDecl, .subscriptDecl, .patternBinding:
                return nil
            default:
                current = n.parent
            }
        }
        return nil
    }

    /// Whether syntax alone shows that the closure is not transformed by a result builder and that none of its call
    /// statements is its value.
    static func isKnownPlainClosure(_ closure: ClosureExprSyntax, options: GeneratorOptions) -> Bool {
        let callee = calleeName(of: closure)
        if let callee, options.voidClosureCallNames.contains(callee) { return true }
        // One statement could be the value of the closure
        guard closure.statements.count >= 2 else { return false }
        if let callee, options.plainClosureCallNames.contains(callee) { return true }
        return containsStatementNoBuilderAccepts(closure)
    }

    /// Name of the function or method that the closure is an argument of.
    static func calleeName(of closure: ClosureExprSyntax) -> String? {
        var current = closure.parent
        while let n = current {
            if let call = n.as(FunctionCallExprSyntax.self) { return ExclusionRules.calleeName(call) }
            // Only through the argument list: the labeled argument, the list, a further trailing closure
            guard n.is(LabeledExprSyntax.self) || n.is(LabeledExprListSyntax.self) || n.is(MultipleTrailingClosureElementSyntax.self)
                || n.is(MultipleTrailingClosureElementListSyntax.self) else { return nil }
            current = n.parent
        }
        return nil
    }

    /// `return`, `guard`, `while`, `repeat`, `defer`, `break`, `continue` among the closure's own statements (nested
    /// closures and functions left out): a closure with one of these is not a result-builder body. An explicit
    /// `return` switches the transform off; the others are rejected by it.
    static func containsStatementNoBuilderAccepts(_ closure: ClosureExprSyntax) -> Bool {
        final class Finder: SyntaxVisitor {
            var found = false
            let root: SyntaxIdentifier
            init(root: SyntaxIdentifier) { self.root = root; super.init(viewMode: .sourceAccurate) }
            override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind { node.id == root ? .visitChildren : .skipChildren }
            override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
            override func visit(_ node: ReturnStmtSyntax) -> SyntaxVisitorContinueKind { found = true; return .skipChildren }
            override func visit(_ node: GuardStmtSyntax) -> SyntaxVisitorContinueKind { found = true; return .skipChildren }
            override func visit(_ node: WhileStmtSyntax) -> SyntaxVisitorContinueKind { found = true; return .skipChildren }
            override func visit(_ node: RepeatStmtSyntax) -> SyntaxVisitorContinueKind { found = true; return .skipChildren }
            override func visit(_ node: DeferStmtSyntax) -> SyntaxVisitorContinueKind { found = true; return .skipChildren }
            override func visit(_ node: BreakStmtSyntax) -> SyntaxVisitorContinueKind { found = true; return .skipChildren }
            override func visit(_ node: ContinueStmtSyntax) -> SyntaxVisitorContinueKind { found = true; return .skipChildren }
        }
        let finder = Finder(root: closure.id)
        finder.walk(closure)
        return finder.found
    }
}
