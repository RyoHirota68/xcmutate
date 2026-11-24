import SwiftSyntax

/// The operators empty-body, compound-assignment, switch-case-removal, try-optional-nil, condition-constant
/// and guard-removal.
///
/// What each one does, and which are on by default, is in docs/operators.md.
final class BodyAndConditionOperatorCollector: SyntaxVisitor {
    let options: GeneratorOptions
    var candidates: [Candidate] = []
    /// `switch-case-removal`: where to insert the `where` guard for each candidate (keyed by region).
    var guardOffsets: [ByteRange: [Int]] = [:]

    init(options: GeneratorOptions) {
        self.options = options
        super.init(viewMode: .sourceAccurate)
    }

    // MARK: empty-body

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        guard options.operators.contains(.emptyBody), let body = node.body, Self.returnsNothing(node),
              Self.isWorthEmptying(body.statements) else { return .visitChildren }
        // The region is everything between the braces (including comments and the newline before `}`), so that it
        // never coincides with the range of a single statement and a trailing line comment stays terminated.
        let region = ByteRange(start: body.leftBrace.endPositionBeforeTrailingTrivia.utf8Offset,
                               end: body.rightBrace.positionAfterSkippingLeadingTrivia.utf8Offset)
        guard region.length > 0 else { return .visitChildren }
        let labels = node.signature.parameterClause.parameters.map { "\($0.firstName.text):" }.joined()
        candidates.append(Candidate(
            op: .emptyBody, node: Syntax(body), region: region, point: region,
            edits: [Edit(range: region, text: "")],
            original: "body of \(node.name.text)(\(labels))", replacement: "{}"))
        return .visitChildren
    }

    static func returnsNothing(_ node: FunctionDeclSyntax) -> Bool {
        guard let type = node.signature.returnClause?.type.trimmedDescription.replacingSpaces() else { return true }
        return ["Void", "()", "Swift.Void"].contains(type)
    }

    /// A body is worth emptying only if it has at least one statement with an effect that `side-effect-removal`
    /// does not already cover. Bodies made only of discarded calls (including `super.f()`-only overrides and
    /// logging-only bodies), early-exit guards and bare `return`s are skipped: removing each call is already a
    /// mutant (or was judged arid), so the whole-body removal would only repeat those results.
    static func isWorthEmptying(_ statements: CodeBlockItemListSyntax) -> Bool {
        for item in statements {
            if let expr = item.item.as(ExprSyntax.self) {
                if StatementCollector.discardedCall(in: expr) != nil { continue }
                return true
            }
            if let stmt = item.item.as(StmtSyntax.self) {
                if let ret = stmt.as(ReturnStmtSyntax.self), ret.expression == nil { continue }
                if let guardStmt = stmt.as(GuardStmtSyntax.self), isPureExit(guardStmt.body) { continue }
                return true
            }
            if let decl = item.item.as(DeclSyntax.self) {
                // Local functions and types have no effect by themselves; a local variable only matters through later statements.
                if decl.is(VariableDeclSyntax.self) || decl.is(FunctionDeclSyntax.self) || decl.is(StructDeclSyntax.self)
                    || decl.is(ClassDeclSyntax.self) || decl.is(EnumDeclSyntax.self) || decl.is(TypeAliasDeclSyntax.self) { continue }
                return true
            }
        }
        return false
    }

    private static func isPureExit(_ block: CodeBlockSyntax) -> Bool {
        block.statements.allSatisfy { item in
            if let ret = item.item.as(ReturnStmtSyntax.self) { return ret.expression == nil }
            return false
        }
    }

    // MARK: compound-assignment, (the other infix operators are in the earlier collectors)

    static let compoundReplacements = ["+=": "-=", "-=": "+=", "*=": "/=", "/=": "*="]

    override func visit(_ node: InfixOperatorExprSyntax) -> SyntaxVisitorContinueKind {
        guard options.operators.contains(.compoundAssignment),
              let token = node.operator.as(BinaryOperatorExprSyntax.self)?.operator,
              let replacement = Self.compoundReplacements[token.text],
              node.parent?.is(CodeBlockItemSyntax.self) == true,
              !(node.rightOperand.is(StringLiteralExprSyntax.self) || node.rightOperand.is(ArrayExprSyntax.self)
                || node.rightOperand.is(DictionaryExprSyntax.self)) else { return .visitChildren }
        let point = token.trimmedByteRange
        candidates.append(Candidate(
            op: .compoundAssignment, node: Syntax(node), region: node.trimmedByteRange, point: point,
            edits: [Edit(range: point, text: replacement)], original: token.text, replacement: replacement))
        return .visitChildren
    }

    // MARK: switch-case-removal

    override func visit(_ node: SwitchExprSyntax) -> SyntaxVisitorContinueKind {
        guard options.operators.contains(.switchCaseRemoval) else { return .visitChildren }
        let cases = node.cases.compactMap { $0.as(SwitchCaseSyntax.self) }
        // Cases inside `#if` are left alone (the list would not be complete).
        guard cases.count == node.cases.count,
              let defaultIndex = cases.firstIndex(where: { $0.label.is(SwitchDefaultLabelSyntax.self) && $0.attribute == nil }) else {
            return .visitChildren
        }
        let defaultBody = cases[defaultIndex].statements.trimmedDescription
        /// The statements that matter: without bare `break`s and calls that are never mutated (logging, crash reporting).
        func effective(_ statements: CodeBlockItemListSyntax) -> [String] {
            statements.compactMap { item in
                if item.item.is(BreakStmtSyntax.self) { return nil }
                if let expr = item.item.as(ExprSyntax.self), let call = StatementCollector.discardedCall(in: expr),
                   ExclusionRules.isAridCall(call, options: options) { return nil }
                return item.trimmedDescription
            }
        }
        let defaultEffective = effective(cases[defaultIndex].statements)
        for (index, switchCase) in cases.enumerated() {
            guard let label = switchCase.label.as(SwitchCaseLabelSyntax.self), switchCase.attribute == nil,
                  !label.caseItems.isEmpty, label.caseItems.allSatisfy({ $0.whereClause == nil }) else { continue }
            let bodyText = switchCase.statements.trimmedDescription
            // Same body as `default`, or falling through into it: removing the case changes nothing.
            if bodyText == defaultBody { continue }
            // …or differs from it only by logging: `case 403: break` next to `default: Crashlytics.record(error)`.
            if effective(switchCase.statements) == defaultEffective { continue }
            if bodyText == "fallthrough", index + 1 == defaultIndex { continue }
            guard let first = label.caseItems.first, let last = label.caseItems.last else { continue }
            let region = ByteRange(start: first.pattern.positionAfterSkippingLeadingTrivia.utf8Offset,
                                   end: last.pattern.endPositionBeforeTrailingTrivia.utf8Offset)
            let offsets = label.caseItems.map { $0.pattern.endPositionBeforeTrailingTrivia.utf8Offset }
            guardOffsets[region] = offsets
            candidates.append(Candidate(
                op: .switchCaseRemoval, node: Syntax(switchCase), region: region, point: region,
                edits: offsets.map { Edit(range: ByteRange(start: $0, end: $0), text: " where false") },
                original: "case \(label.caseItems.trimmedDescription)", replacement: "default"))
        }
        return .visitChildren
    }

    // MARK: try-optional-nil

    override func visit(_ node: TryExprSyntax) -> SyntaxVisitorContinueKind {
        guard options.operators.contains(.tryOptionalNil), node.questionOrExclamationMark?.tokenKind == .postfixQuestionMark,
              let parent = node.parent else { return .visitChildren }
        // As a statement, or assigned to `_`: the same as removing the statement (side-effect-removal).
        // The exception is the single expression of a function or getter that returns a value (an implicit return).
        if let item = parent.as(CodeBlockItemSyntax.self) {
            guard let list = item.parent?.as(CodeBlockItemListSyntax.self), list.count == 1,
                  let owner = StatementCollector.bodyOwner(of: item), ExclusionRules.returnsValue(owner),
                  ExclusionRules.isDirectBody(list, of: owner) else { return .visitChildren }
        }
        if let infix = parent.as(InfixOperatorExprSyntax.self), infix.operator.is(AssignmentExprSyntax.self),
           infix.leftOperand.is(DiscardAssignmentExprSyntax.self) { return .visitChildren }
        // `return try? f()` in a function returning an Optional: return-value already replaces `f()` with `nil` there.
        if parent.is(ReturnStmtSyntax.self), options.operators.contains(.returnValue),
           let owner = ExtendedOperatorCollector.returningDecl(of: parent),
           let type = ExtendedOperatorCollector.returnType(of: owner),
           ExtendedOperatorCollector.defaultValue(forType: type) == "nil" { return .visitChildren }
        let range = node.trimmedByteRange
        candidates.append(Candidate(
            op: .tryOptionalNil, node: Syntax(node), region: range, point: range,
            edits: [Edit(range: range, text: "nil")], original: node.trimmedDescription, replacement: "nil"))
        return .visitChildren
    }

    // MARK: condition-constant (if -> false) and guard-removal (guard -> true)

    override func visit(_ node: ConditionElementListSyntax) -> SyntaxVisitorContinueKind {
        guard let parent = node.parent else { return .visitChildren }
        func expression(_ element: ConditionElementSyntax) -> ExprSyntax? {
            guard case let .expression(expr) = element.condition, !expr.is(BooleanLiteralExprSyntax.self),
                  !expr.is(TryExprSyntax.self), !expr.is(AwaitExprSyntax.self) else { return nil }
            return expr
        }
        var target: (ExprSyntax, String, MutationOperator)?
        if parent.is(GuardStmtSyntax.self), options.operators.contains(.guardRemoval) {
            // With two or more conditions, condition-removal already turns each one into `true`.
            if node.count == 1, let expr = node.first.flatMap(expression) { target = (expr, "true", .guardRemoval) }
        } else if let ifExpr = parent.as(IfExprSyntax.self), options.operators.contains(.conditionConstant) {
            // An `if` without `else` whose body only logs: skipping it changes nothing a test should assert on.
            let onlyArid = ifExpr.elseBody == nil && !ifExpr.body.statements.isEmpty && ifExpr.body.statements.allSatisfy { item in
                guard let expr = item.item.as(ExprSyntax.self), let call = StatementCollector.discardedCall(in: expr) else { return false }
                return ExclusionRules.isAridCall(call, options: options)
            }
            // One per `if`: the last plain condition, so that the conditions before it are still evaluated.
            if !onlyArid, let expr = node.reversed().lazy.compactMap(expression).first { target = (expr, "false", .conditionConstant) }
        }
        if let (expr, literal, op) = target {
            let range = expr.trimmedByteRange
            candidates.append(Candidate(
                op: op, node: Syntax(expr), region: range, point: range,
                edits: [Edit(range: range, text: literal)], original: expr.trimmedDescription, replacement: literal))
        }
        return .visitChildren
    }
}
