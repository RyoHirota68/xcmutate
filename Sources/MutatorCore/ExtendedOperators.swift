import SwiftSyntax

/// The operators for return values and control flow (return value replacement, early return, condition removal, continue ↔ break, removing normalization calls).
final class ExtendedOperatorCollector: SyntaxVisitor {
    let options: GeneratorOptions
    var candidates: [Candidate] = []

    init(options: GeneratorOptions) {
        self.options = options
        super.init(viewMode: .sourceAccurate)
    }

    // MARK: return-value

    override func visit(_ node: ReturnStmtSyntax) -> SyntaxVisitorContinueKind {
        guard options.operators.contains(.returnValue), var expr = node.expression,
              let owner = Self.returningDecl(of: Syntax(node)) else { return .visitChildren }
        // For `return try f()` / `return await f()`, replace the inside of the try / await (since it cannot be placed inside a ternary branch)
        while true {
            if let t = expr.as(TryExprSyntax.self) { expr = t.expression } else if let a = expr.as(AwaitExprSyntax.self) { expr = a.expression } else { break }
        }
        let text = expr.trimmedDescription
        if text == "self" || text == "Self()" { return .visitChildren }
        // `return switch …` / `return if …` cannot be placed inside a ternary branch
        if expr.is(SwitchExprSyntax.self) || expr.is(IfExprSyntax.self) { return .visitChildren }
        let range = expr.trimmedByteRange

        var replacements: [String] = []
        if let member = Self.implicitMember(expr) {
            // Another enum case returned in the same function
            let others = Self.returnedImplicitMembers(in: owner).filter { $0 != member }
            replacements = others.prefix(options.maxReturnAlternatives).map { ".\($0)" }
        } else if let type = Self.returnType(of: owner), let value = Self.defaultValue(forType: type), value != text,
                  !(value == "0" && ["0", "0.0"].contains(text)) {
            replacements = [value]
        }
        for replacement in replacements {
            candidates.append(Candidate(
                op: .returnValue, node: Syntax(expr), region: range, point: range,
                edits: [Edit(range: range, text: replacement)], original: text, replacement: replacement))
        }
        return .visitChildren
    }

    /// A declaration whose return type is known (function, get accessor, subscript). nil for closures and initializers.
    static func returningDecl(of node: Syntax) -> Syntax? {
        var current = node.parent
        while let n = current {
            switch n.kind {
            case .closureExpr, .initializerDecl, .deinitializerDecl, .sourceFile:
                return nil
            case .functionDecl, .subscriptDecl:
                return n
            case .accessorDecl:
                return n.as(AccessorDeclSyntax.self)?.accessorSpecifier.tokenKind == .keyword(.get) ? n : nil
            case .patternBinding:
                return n
            default:
                current = n.parent
            }
        }
        return nil
    }

    static func returnType(of owner: Syntax) -> String? {
        if let f = owner.as(FunctionDeclSyntax.self) { return f.signature.returnClause?.type.trimmedDescription }
        if let s = owner.as(SubscriptDeclSyntax.self) { return s.returnClause.type.trimmedDescription }
        var current: Syntax? = owner
        while let n = current {
            if let binding = n.as(PatternBindingSyntax.self) { return binding.typeAnnotation?.type.trimmedDescription }
            current = n.parent
        }
        return nil
    }

    /// "Another value" that can be built from the return type annotation. nil if the type is unknown, generic, or Bool.
    static func defaultValue(forType raw: String) -> String? {
        let type = raw.replacingSpaces()
        if type.hasSuffix("?") || type.hasPrefix("Optional<") { return "nil" }
        if type.hasSuffix("!") { return nil }
        if type.hasPrefix("[") && type.hasSuffix("]") {
            return topLevelColon(in: String(type.dropFirst().dropLast())) ? "[:]" : "[]"
        }
        if type.hasPrefix("Array<") || type.hasPrefix("Set<") { return "[]" }
        if type.hasPrefix("Dictionary<") { return "[:]" }
        if type == "String" { return "\"\"" }
        let numeric: Set<String> = ["Int", "Int8", "Int16", "Int32", "Int64", "UInt", "UInt8", "UInt16", "UInt32", "UInt64",
                                    "Double", "Float", "CGFloat", "TimeInterval", "Decimal"]
        if numeric.contains(type) { return "0" }
        return nil
    }

    private static func topLevelColon(in text: String) -> Bool {
        var depth = 0
        for c in text {
            if c == "[" || c == "(" || c == "<" { depth += 1 }
            if c == "]" || c == ")" || c == ">" { depth -= 1 }
            if c == ":" && depth == 0 { return true }
        }
        return false
    }

    /// If this is an implicit member expression without arguments (`.noVariant`), its name.
    static func implicitMember(_ expr: ExprSyntax) -> String? {
        guard let member = expr.as(MemberAccessExprSyntax.self), member.base == nil,
              member.declName.argumentNames == nil else { return nil }
        return member.declName.baseName.text
    }

    /// Implicit member expressions that appear, within the declaration (excluding nested closures and functions), as return expressions or their ternary branches (in order of appearance).
    static func returnedImplicitMembers(in owner: Syntax) -> [String] {
        final class Finder: SyntaxVisitor {
            var names: [String] = []
            let root: Syntax
            init(root: Syntax) { self.root = root; super.init(viewMode: .sourceAccurate) }
            override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
            override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind { node.id == root.id ? .visitChildren : .skipChildren }
            override func visit(_ node: ReturnStmtSyntax) -> SyntaxVisitorContinueKind {
                guard let expr = node.expression else { return .skipChildren }
                var exprs = [expr]
                if let ternary = expr.as(TernaryExprSyntax.self) { exprs = [ternary.thenExpression, ternary.elseExpression] }
                for e in exprs {
                    if let name = ExtendedOperatorCollector.implicitMember(e), !names.contains(name) { names.append(name) }
                }
                return .skipChildren
            }
        }
        let finder = Finder(root: owner)
        finder.walk(owner)
        return finder.names
    }

    // MARK: early-return

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        guard options.operators.contains(.earlyReturn), let body = node.body,
              let last = body.statements.last?.item.as(ReturnStmtSyntax.self), let expr = last.expression else {
            return .visitChildren
        }
        // The last statement is `return flag` or `return flag ? A : B` (A is an implicit member, a literal, or nil)
        var flag: String?
        var value: String?
        if let ref = expr.as(DeclReferenceExprSyntax.self) {
            flag = ref.baseName.text
            value = "true"
        } else if let ternary = expr.as(TernaryExprSyntax.self), let ref = ternary.condition.as(DeclReferenceExprSyntax.self),
                  Self.isSimpleValue(ternary.thenExpression) {
            flag = ref.baseName.text
            value = ternary.thenExpression.trimmedDescription
        }
        guard let flag, let value else { return .visitChildren }
        // The flag is a local variable declared directly in the body as `var flag = false`
        let declared = body.statements.contains { item in
            guard let variable = item.item.as(VariableDeclSyntax.self), variable.bindingSpecifier.tokenKind == .keyword(.var) else { return false }
            return variable.bindings.contains { binding in
                binding.pattern.trimmedDescription == flag
                    && binding.initializer?.value.as(BooleanLiteralExprSyntax.self)?.literal.tokenKind == .keyword(.false)
            }
        }
        guard declared else { return .visitChildren }

        final class AssignmentFinder: SyntaxVisitor {
            let flag: String
            var found: [(InfixOperatorExprSyntax, Bool)] = []
            init(flag: String) { self.flag = flag; super.init(viewMode: .sourceAccurate) }
            override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
            override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
            override func visit(_ node: InfixOperatorExprSyntax) -> SyntaxVisitorContinueKind {
                if node.operator.is(AssignmentExprSyntax.self),
                   node.leftOperand.as(DeclReferenceExprSyntax.self)?.baseName.text == flag,
                   node.rightOperand.as(BooleanLiteralExprSyntax.self)?.literal.tokenKind == .keyword(.true),
                   node.parent?.is(CodeBlockItemSyntax.self) == true {
                    var inLoop = false
                    var current = node.parent
                    while let n = current, !n.is(FunctionDeclSyntax.self) {
                        if n.is(ForStmtSyntax.self) || n.is(WhileStmtSyntax.self) || n.is(RepeatStmtSyntax.self) { inLoop = true }
                        current = n.parent
                    }
                    found.append((node, inLoop))
                }
                return .visitChildren
            }
        }
        let finder = AssignmentFinder(flag: flag)
        finder.walk(body)
        for (assignment, inLoop) in finder.found where inLoop {
            let range = assignment.trimmedByteRange
            let replacement = "return \(value)"
            candidates.append(Candidate(
                op: .earlyReturn, node: Syntax(assignment), region: range, point: range,
                edits: [Edit(range: range, text: replacement)],
                original: assignment.trimmedDescription, replacement: replacement))
        }
        return .visitChildren
    }

    static func isSimpleValue(_ expr: ExprSyntax) -> Bool {
        implicitMember(expr) != nil || expr.is(BooleanLiteralExprSyntax.self) || expr.is(IntegerLiteralExprSyntax.self)
            || expr.is(NilLiteralExprSyntax.self) || expr.is(FloatLiteralExprSyntax.self)
            || (expr.as(StringLiteralExprSyntax.self).map { $0.segments.allSatisfy { $0.is(StringSegmentSyntax.self) } } ?? false)
    }

    // MARK: condition-removal

    override func visit(_ node: ConditionElementListSyntax) -> SyntaxVisitorContinueKind {
        guard options.operators.contains(.conditionRemoval), node.count >= 2,
              node.parent?.is(IfExprSyntax.self) == true || node.parent?.is(GuardStmtSyntax.self) == true else {
            return .visitChildren
        }
        for element in node {
            guard case let .expression(expr) = element.condition,
                  !expr.is(TryExprSyntax.self), !expr.is(AwaitExprSyntax.self),
                  expr.as(BooleanLiteralExprSyntax.self)?.literal.tokenKind != .keyword(.true) else { continue }
            let range = expr.trimmedByteRange
            candidates.append(Candidate(
                op: .conditionRemoval, node: Syntax(expr), region: range, point: range,
                edits: [Edit(range: range, text: "true")],
                original: expr.trimmedDescription, replacement: "true"))
        }
        return .visitChildren
    }

    // MARK: loop-control

    override func visit(_ node: ContinueStmtSyntax) -> SyntaxVisitorContinueKind {
        if options.operators.contains(.loopControl), node.label == nil, Self.enclosingLoop(of: Syntax(node), allowSwitch: true),
           !Self.breakIsEquivalent(to: Syntax(node)) {
            add(loopControl: Syntax(node), original: "continue", replacement: "break")
        }
        return .visitChildren
    }

    override func visit(_ node: BreakStmtSyntax) -> SyntaxVisitorContinueKind {
        // Turning a break inside a switch into continue is equivalent if no statement of the loop body follows the switch
        if options.operators.contains(.loopControl), node.label == nil, Self.enclosingLoop(of: Syntax(node), allowSwitch: true),
           !Self.breakIsEquivalent(to: Syntax(node)) {
            add(loopControl: Syntax(node), original: "break", replacement: "continue")
        }
        return .visitChildren
    }

    private func add(loopControl node: Syntax, original: String, replacement: String) {
        guard node.parent?.is(CodeBlockItemSyntax.self) == true else { return }
        let range = node.trimmedByteRange
        candidates.append(Candidate(
            op: .loopControl, node: node, region: range, point: range,
            edits: [Edit(range: range, text: replacement)], original: original, replacement: replacement))
    }

    /// Whether turning a `continue` inside a `switch` into `break` is equivalent. `break` only leaves the `switch`, so
    /// it is equivalent if no statement runs between the `switch` and the end of the loop body (i.e. it is the last statement at every level).
    static func breakIsEquivalent(to node: Syntax) -> Bool {
        var current = node.parent
        var switchNode: Syntax?
        while let n = current {
            if n.is(SwitchExprSyntax.self) { switchNode = n; break }
            if n.is(ForStmtSyntax.self) || n.is(WhileStmtSyntax.self) || n.is(RepeatStmtSyntax.self) { return false }
            current = n.parent
        }
        guard var item: Syntax = switchNode else { return false }
        // From the switch upward until the loop body is reached, it must be the last statement in every statement list
        while let parent = item.parent {
            if let list = parent.as(CodeBlockItemListSyntax.self) {
                guard list.last?.id == item.id else { return false }
                if let block = list.parent?.as(CodeBlockSyntax.self), let owner = block.parent,
                   owner.is(ForStmtSyntax.self) || owner.is(WhileStmtSyntax.self) || owner.is(RepeatStmtSyntax.self) {
                    // In any loop, both continue and "leave the switch and reach the end of the body" proceed next to the condition evaluation (or the next element)
                    _ = owner
                    return true
                }
            }
            if parent.is(ClosureExprSyntax.self) || parent.is(FunctionDeclSyntax.self) { return false }
            item = parent
        }
        return false
    }

    /// Whether it is inside a loop (without crossing closure/function boundaries). A `break` inside a `switch` is also a target if it is inside a loop.
    static func enclosingLoop(of node: Syntax, allowSwitch: Bool) -> Bool {
        var current = node.parent
        while let n = current {
            switch n.kind {
            case .forStmt, .whileStmt, .repeatStmt:
                return true
            case .closureExpr, .functionDecl, .initializerDecl, .accessorDecl, .sourceFile:
                return false
            default:
                current = n.parent
            }
        }
        return false
    }

    // MARK: normalization-removal

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        guard options.operators.contains(.normalizationRemoval),
              let member = node.calledExpression.as(MemberAccessExprSyntax.self), let base = member.base,
              options.normalizationMethodNames.contains(member.declName.baseName.text),
              node.trailingClosure == nil else { return .visitChildren }
        let callRange = node.trimmedByteRange
        let point = ByteRange(start: member.period.positionAfterSkippingLeadingTrivia.utf8Offset, end: callRange.end)
        // If an optional chain continues after the call (`user?.name.lowercased().hasPrefix("a")`),
        // widen the replaced range to the whole chain, because wrapping only the call in parentheses cuts the chain and changes the meaning.
        var outer = Syntax(node)
        if ExclusionRules.containsChainOptional(Syntax(node)) {
            while let parent = outer.parent, ExclusionRules.continuesPostfixChain(parent: parent, child: outer) {
                outer = parent
            }
        }
        var edits: [Edit]
        if outer.id != Syntax(node).id {
            // Middle of the chain: remove only the `.lowercased()` part (keep the `?`)
            edits = [Edit(range: ByteRange(start: base.trimmedByteRange.end, end: callRange.end), text: "")]
        } else if let chained = base.as(OptionalChainingExprSyntax.self) {
            // End of the chain: for `x?.lowercased()` remove the `?` too (leaving only `x?` does not compile)
            edits = [Edit(range: ByteRange(start: chained.expression.trimmedByteRange.end, end: callRange.end), text: "")]
        } else if ExclusionRules.containsChainOptional(Syntax(node)) {
            edits = [Edit(range: ByteRange(start: base.trimmedByteRange.end, end: callRange.end), text: "")]
        } else {
            // The receiver alone has another type when it is a `Character` or a `Substring` (`first.uppercased()`,
            // `key[range].lowercased()`), and the two branches of the switch must have one type.
            // `String(describing:)` gives the receiver's own text for all three, and has a single generic
            // initializer (`String(receiver)` has dozens of overloads, which next to a `+` is enough to make the
            // type checker give up)
            let start = base.trimmedByteRange.start
            edits = [Edit(range: ByteRange(start: start, end: start), text: "String(describing: "),
                     Edit(range: ByteRange(start: base.trimmedByteRange.end, end: callRange.end), text: ")")]
        }
        candidates.append(Candidate(
            op: .normalizationRemoval, node: outer, region: outer.trimmedByteRange, point: point,
            edits: edits,
            original: String(node.trimmedDescription.dropFirst(base.trimmedDescription.count)), replacement: ""))
        return .visitChildren
    }
}

/// The operators for conditions and operands (condition negation, Bool return value negation, operand removal, arithmetic, `??` default value, min ↔ max).
final class ConditionAndOperandOperatorCollector: SyntaxVisitor {
    let options: GeneratorOptions
    var candidates: [Candidate] = []

    init(options: GeneratorOptions) {
        self.options = options
        super.init(viewMode: .sourceAccurate)
    }

    /// Whether this is a "bare" Bool expression containing no operator (a target for negation and removal).
    static func isBare(_ expr: ExprSyntax) -> Bool {
        switch expr.kind {
        case .infixOperatorExpr, .prefixOperatorExpr, .booleanLiteralExpr, .ternaryExpr, .tryExpr, .awaitExpr,
             .tupleExpr, .sequenceExpr, .closureExpr, .ifExpr, .switchExpr, .unsafeExpr:
            return false
        default:
            return true
        }
    }

    private func negation(_ expr: ExprSyntax, op: MutationOperator) {
        // `func stub() -> Bool { fatalError("not implemented") }`: there is no value to negate
        if let call = StatementCollector.discardedCall(in: expr), let name = ExclusionRules.calleeName(call), options.neverReturningNames.contains(name) { return }
        let range = expr.trimmedByteRange
        let text = expr.trimmedDescription
        candidates.append(Candidate(
            op: op, node: Syntax(expr), region: range, point: range,
            edits: [Edit(range: ByteRange(start: range.start, end: range.start), text: "!("),
                    Edit(range: ByteRange(start: range.end, end: range.end), text: ")")],
            original: text, replacement: "!(\(text))"))
    }

    // condition-negation
    override func visit(_ node: ConditionElementListSyntax) -> SyntaxVisitorContinueKind {
        guard options.operators.contains(.conditionNegation),
              node.parent?.is(IfExprSyntax.self) == true || node.parent?.is(GuardStmtSyntax.self) == true else {
            return .visitChildren
        }
        for element in node {
            if case let .expression(expr) = element.condition, Self.isBare(expr) {
                negation(expr, op: .conditionNegation)
            }
        }
        return .visitChildren
    }

    // return-negation (explicit return)
    override func visit(_ node: ReturnStmtSyntax) -> SyntaxVisitorContinueKind {
        guard options.operators.contains(.returnNegation), let expr = node.expression, Self.isBare(expr),
              let owner = ExtendedOperatorCollector.returningDecl(of: Syntax(node)),
              ExtendedOperatorCollector.returnType(of: owner)?.replacingSpaces() == "Bool" else { return .visitChildren }
        negation(expr, op: .returnNegation)
        return .visitChildren
    }

    // return-negation (function whose body is a single expression)
    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        if options.operators.contains(.returnNegation),
           node.signature.returnClause?.type.trimmedDescription.replacingSpaces() == "Bool",
           let statements = node.body?.statements, statements.count == 1,
           let expr = statements.first?.item.as(ExprSyntax.self), Self.isBare(expr) {
            negation(expr, op: .returnNegation)
        }
        return .visitChildren
    }

    // return-negation (getter whose body is a single expression: `var isX: Bool { foo }`)
    override func visit(_ node: PatternBindingSyntax) -> SyntaxVisitorContinueKind {
        if options.operators.contains(.returnNegation),
           node.typeAnnotation?.type.trimmedDescription.replacingSpaces() == "Bool",
           case let .getter(statements)? = node.accessorBlock?.accessors, statements.count == 1,
           let expr = statements.first?.item.as(ExprSyntax.self), Self.isBare(expr) {
            negation(expr, op: .returnNegation)
        }
        return .visitChildren
    }

    override func visit(_ node: AccessorDeclSyntax) -> SyntaxVisitorContinueKind {
        if options.operators.contains(.returnNegation), node.accessorSpecifier.tokenKind == .keyword(.get),
           let statements = node.body?.statements, statements.count == 1,
           let expr = statements.first?.item.as(ExprSyntax.self), Self.isBare(expr) {
            var current = node.parent
            while let n = current, !n.is(PatternBindingSyntax.self), !n.is(SubscriptDeclSyntax.self) { current = n.parent }
            let type = current?.as(PatternBindingSyntax.self)?.typeAnnotation?.type.trimmedDescription
                ?? current?.as(SubscriptDeclSyntax.self)?.returnClause.type.trimmedDescription
            if type?.replacingSpaces() == "Bool" { negation(expr, op: .returnNegation) }
        }
        return .visitChildren
    }

    override func visit(_ node: InfixOperatorExprSyntax) -> SyntaxVisitorContinueKind {
        guard let opToken = node.operator.as(BinaryOperatorExprSyntax.self)?.operator else { return .visitChildren }
        let op = opToken.text
        // operand-removal
        if options.operators.contains(.operandRemoval), op == "&&" || op == "||" {
            let literal = op == "&&" ? "true" : "false"
            for operand in [node.leftOperand, node.rightOperand] where !operand.is(BooleanLiteralExprSyntax.self) {
                let range = operand.trimmedByteRange
                candidates.append(Candidate(
                    op: .operandRemoval, node: Syntax(operand), region: range, point: range,
                    edits: [Edit(range: range, text: literal)],
                    original: operand.trimmedDescription, replacement: literal))
            }
        }
        // arithmetic
        let arithmetic = ["+": "-", "-": "+", "*": "/", "/": "*"]
        if options.operators.contains(.arithmetic), let replacement = arithmetic[op], Self.isArithmeticCandidate(node, replacement: replacement) {
            let point = opToken.trimmedByteRange
            candidates.append(Candidate(
                op: .arithmetic, node: Syntax(node), region: node.trimmedByteRange, point: point,
                edits: [Edit(range: point, text: replacement)], original: op, replacement: replacement))
        }
        // nil-coalescing-default
        if options.operators.contains(.nilCoalescingDefault), op == "??" {
            let rhs = node.rightOperand
            var replacement: String?
            if let int = rhs.as(IntegerLiteralExprSyntax.self) {
                replacement = int.literal.text == "0" ? "1" : "0"
            } else if let float = rhs.as(FloatLiteralExprSyntax.self) {
                replacement = Double(float.literal.text) == 0 ? "1" : "0"
            } else if let string = rhs.as(StringLiteralExprSyntax.self), string.openingPounds == nil,
                      string.segments.allSatisfy({ $0.is(StringSegmentSyntax.self) }), string.openingQuote.text == "\"" {
                replacement = string.segments.trimmedDescription.isEmpty ? "\"mutated\"" : "\"\""
            }
            if let replacement {
                let range = rhs.trimmedByteRange
                candidates.append(Candidate(
                    op: .nilCoalescingDefault, node: Syntax(rhs), region: range, point: range,
                    edits: [Edit(range: range, text: replacement)], original: rhs.trimmedDescription, replacement: replacement))
            }
        }
        return .visitChildren
    }

    /// Whether replacing the operator can compile and says something about the code:
    /// - not when a string, array or dictionary literal is anywhere in the operands (`name + "#" + String(n)` is
    ///   `(name + "#") + String(n)`: the outer `+` concatenates too, and `-` does not exist for strings), or an
    ///   operand is text by the name of the call that makes it (`a.lowercased() + b`);
    /// - not `x * 0` → `x / 0` (a division by a literal zero is a compile error);
    /// - not when both operands are made of number literals only (a constant, and in a place without a context
    ///   type the nested switches make the type checker give up: `"\(2 / 1 / 3)"`).
    static func isArithmeticCandidate(_ node: InfixOperatorExprSyntax, replacement: String) -> Bool {
        func holdsCollectionLiteral(_ expr: ExprSyntax) -> Bool {
            expr.tokens(viewMode: .sourceAccurate).contains { token in
                var current = token.parent
                while let n = current, n.id != expr.id {
                    if n.is(StringLiteralExprSyntax.self) || n.is(ArrayExprSyntax.self) || n.is(DictionaryExprSyntax.self) { return true }
                    current = n.parent
                }
                return expr.is(StringLiteralExprSyntax.self) || expr.is(ArrayExprSyntax.self) || expr.is(DictionaryExprSyntax.self)
            }
        }
        if holdsCollectionLiteral(node.leftOperand) || holdsCollectionLiteral(node.rightOperand) { return false }
        // An operand that is text by the name of what makes it: `a.lowercased() + b`, `String(n) + unit`
        func isText(_ expr: ExprSyntax) -> Bool {
            let names: Set<String> = ["String", "lowercased", "uppercased", "trimmingCharacters", "joined", "description", "debugDescription",
                                      "localizedDescription", "capitalized", "localizedLowercase", "localizedUppercase"]
            if let call = expr.as(FunctionCallExprSyntax.self), let name = ExclusionRules.calleeName(call) { return names.contains(name) }
            if let member = expr.as(MemberAccessExprSyntax.self) { return names.contains(member.declName.baseName.text) }
            return false
        }
        if isText(node.leftOperand) || isText(node.rightOperand) { return false }
        func isZero(_ expr: ExprSyntax) -> Bool {
            if let int = expr.as(IntegerLiteralExprSyntax.self) { return Int(int.literal.text.filter { $0 != "_" }) == 0 }
            if let float = expr.as(FloatLiteralExprSyntax.self) { return Double(float.literal.text.filter { $0 != "_" }) == 0 }
            return false
        }
        if replacement == "/", isZero(node.rightOperand) { return false }
        func isNumberLiteralsOnly(_ expr: ExprSyntax) -> Bool {
            expr.tokens(viewMode: .sourceAccurate).allSatisfy { token in
                switch token.tokenKind {
                case .integerLiteral, .floatLiteral, .binaryOperator, .leftParen, .rightParen, .prefixOperator: true
                default: false
                }
            }
        }
        if isNumberLiteralsOnly(node.leftOperand), isNumberLiteralsOnly(node.rightOperand) { return false }
        return true
    }

    // min-max
    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        if options.operators.contains(.minMax), let callee = node.calledExpression.as(DeclReferenceExprSyntax.self),
           ["min", "max"].contains(callee.baseName.text), node.arguments.count == 2,
           node.arguments.allSatisfy({ $0.label == nil }), node.trailingClosure == nil {
            let replacement = callee.baseName.text == "min" ? "max" : "min"
            let point = callee.trimmedByteRange
            candidates.append(Candidate(
                op: .minMax, node: Syntax(node), region: node.trimmedByteRange, point: point,
                edits: [Edit(range: point, text: replacement)], original: callee.baseName.text, replacement: replacement))
        }
        return .visitChildren
    }
}

extension String {
    func replacingSpaces() -> String { String(filter { $0 != " " }) }
}
