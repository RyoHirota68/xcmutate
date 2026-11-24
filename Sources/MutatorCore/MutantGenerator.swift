import SwiftOperators
import SwiftParser
import SwiftSyntax

/// Generation result for one file.
public struct GenerationResult: Sendable {
    /// Generated mutants (`id` is a provisional sequence starting at 0; `FileProcessor` reassigns it).
    public var mutants: [Mutant]
    public var ignored: [IgnoredMutant]
    /// Files with parse errors are not mutated. The reason is stored here in that case.
    public var skippedReason: String?
    /// Number of mutants dropped as outside the diff (when `changedLines` is passed).
    public var outOfDiffCount: Int = 0
    /// Problems noticed during generation (such as unknown operator names in disable comments). Not silently ignored; the caller reports them.
    public var warnings: [GenerationWarning] = []
}

public struct GenerationWarning: Codable, Hashable, Sendable {
    public var line: Int
    public var message: String
}

/// Mechanically creates mutants from source text (a pure function).
///
/// The syntax tree is used only inside this function; only UTF-8 byte ranges and text remain in the result.
public struct MutantGenerator: Sendable {
    public var options: GeneratorOptions

    public init(options: GeneratorOptions = GeneratorOptions()) {
        self.options = options
    }

    /// - Parameter changedLines: Line ranges of the diff. When passed, mutants are narrowed by the diff **before** the per-expression switch limit is applied
    ///   (so that mutants on changed lines are not pushed out of the limit by mutants on unchanged lines).
    public func generate(source: String, filePath: String, changedLines: [ClosedRange<Int>]? = nil) -> GenerationResult {
        let tree = Parser.parse(source: source)
        if tree.hasError {
            return GenerationResult(mutants: [], ignored: [], skippedReason: "parse-error")
        }

        // Fold by operator precedence. Operators declared in the file are added to the table too.
        var table = OperatorTable.standardOperators
        if !options.extraOperatorDeclarations.isEmpty {
            table.addSourceFile(Parser.parse(source: options.extraOperatorDeclarations)) { _ in }
        }
        table.addSourceFile(tree) { _ in }

        // First find the sequences that cannot be folded (containing custom operators of unknown precedence) and exclude their ranges.
        let unfoldable = UnfoldableSequenceFinder(table: table).find(in: tree)

        let folded = table.foldAll(tree) { _ in }
        guard let foldedFile = folded.as(SourceFileSyntax.self), foldedFile.description == source else {
            return GenerationResult(mutants: [], ignored: [], skippedReason: "fold-changed-text")
        }

        let bytes = Array(source.utf8)
        let converter = SourceLocationConverter(fileName: filePath, tree: foldedFile)
        let disabled = DisableComments(source: source, commentLines: DisableComments.commentLines(in: foldedFile, converter: converter))
        // Declarations of this file that the rules below need, added to those of the other files of the project
        let declarations = ProjectDeclarationFinder(viewMode: .sourceAccurate)
        declarations.walk(foldedFile)
        var options = self.options
        options.neverReturningNames.formUnion(declarations.neverReturningNames)
        options.resultBuilderNames.formUnion(declarations.resultBuilderNames)

        let collector = CandidateCollector(options: options, viewMode: .sourceAccurate)
        collector.walk(foldedFile)
        let statements = StatementCollector(options: options)
        statements.walk(foldedFile)
        let extra = ExtendedOperatorCollector(options: options)
        extra.walk(foldedFile)
        let conditionsAndOperands = ConditionAndOperandOperatorCollector(options: options)
        conditionsAndOperands.walk(foldedFile)
        let bodiesAndConditions = BodyAndConditionOperatorCollector(options: options)
        bodiesAndConditions.walk(foldedFile)
        let returnsAndClosures = ReturnAndClosureOperatorCollector(options: options)
        returnsAndClosures.walk(foldedFile)
        let candidates = (collector.candidates + statements.candidates + extra.candidates + conditionsAndOperands.candidates + bodiesAndConditions.candidates + returnsAndClosures.candidates)
            .sorted { $0.point.start < $1.point.start }

        var mutants: [Mutant] = []
        var ignored: [IgnoredMutant] = []
        var usedKeys: [String: [String]] = [:]
        var keyWarnings: [GenerationWarning] = []

        for candidate in candidates {
            let startLoc = converter.location(for: AbsolutePosition(utf8Offset: candidate.point.start))
            let endLoc = converter.location(for: AbsolutePosition(utf8Offset: candidate.point.end))
            let start = SourcePosition(line: startLoc.line, column: startLoc.column)
            let end = SourcePosition(line: endLoc.line, column: endLoc.column)
            let declPath = DeclPath.of(candidate.node)

            // The project's own choice comes first, so that the report names it
            var reason: IgnoreReason? = DeclarationPatterns.excludes(DeclPath.components(of: candidate.node), patterns: options.excludedDeclarationPatterns)
                ? .excludedDeclaration : nil
            if reason == nil, candidate.op == .sideEffectRemoval || candidate.op == .closureStatementRemoval {
                reason = ExclusionRules.statementReason(for: candidate, options: options)
            }
            if reason == nil { reason = ExclusionRules.reason(for: candidate, options: options) }
            if reason == nil, unfoldable.contains(where: { $0.overlaps(candidate.region) }) {
                reason = .unfoldableOperators
            }
            if reason == nil, disabled.isDisabled(line: start.line, operator: candidate.op) {
                reason = .disabledByComment
            }

            var mutatedExpression: String?
            if reason == nil {
                let raw = Self.applyEdits(bytes: bytes, region: candidate.region, edits: candidate.edits)
                mutatedExpression = Flattener.flatten(raw)
                if mutatedExpression == nil { reason = .cannotFlatten }
            }

            if let reason {
                ignored.append(IgnoredMutant(
                    operator: candidate.op, file: filePath, enclosingDecl: declPath,
                    point: candidate.point, start: start,
                    original: candidate.original, replacement: candidate.replacement, reason: reason))
                continue
            }

            let originalExpression = Self.text(bytes, candidate.region)
            let hashInput = StableKey.hashInput(
                signatures: DeclPath.signatures(of: candidate.node), syntaxPath: SyntaxPath.of(candidate.node), op: candidate.op,
                original: StableKey.normalized(candidate.keyOriginal ?? originalExpression), replacement: mutatedExpression!)
            var key = StableKey.make(file: filePath, declPath: declPath, hashInput: hashInput, op: candidate.op)
            if let earlier = usedKeys[key] {
                // The same key again. With the same hash input these are identical declarations (the branches of an `#if`),
                // told apart by order; with another input the hash collided, which must not pass unnoticed.
                if !earlier.contains(hashInput) {
                    keyWarnings.append(GenerationWarning(line: start.line, message: "stable key collision: \(key) also names another mutant of this file; the later one gets a numbered key (please report this)"))
                }
                usedKeys[key, default: []].append(hashInput)
                key += "#\(earlier.count + 1)"
            } else {
                usedKeys[key] = [hashInput]
            }

            let regionStart = converter.location(for: AbsolutePosition(utf8Offset: candidate.region.start)).line
            let regionEnd = converter.location(for: AbsolutePosition(utf8Offset: candidate.region.end)).line
            mutants.append(Mutant(
                id: mutants.count, key: key, operator: candidate.op, file: filePath,
                enclosingDecl: declPath, region: candidate.region, point: candidate.point,
                start: start, end: end, original: candidate.original, replacement: candidate.replacement,
                originalExpression: originalExpression,
                mutatedExpression: mutatedExpression!,
                regionLines: LineSpan(start: regionStart, end: regionEnd),
                scope: ScopeFinder.of(candidate.node, converter: converter),
                guardOffsets: candidate.op.guardsCase ? bodiesAndConditions.guardOffsets[candidate.region] : nil))
        }

        func ignore(_ m: Mutant, _ reason: IgnoreReason) {
            ignored.append(IgnoredMutant(
                operator: m.operator, file: m.file, enclosingDecl: m.enclosingDecl, point: m.point,
                start: m.start, original: m.original, replacement: m.replacement, reason: reason))
        }

        // If two operators produce the same rewrite on the same range, keep only one (the one found first).
        var seenRewrites: Set<String> = []
        mutants.removeAll { m in
            guard !m.isStatement else { return false }
            let rewrite = "\(m.region.start):\(m.region.end):\(m.mutatedExpression.filter { !$0.isWhitespace })"
            if seenRewrites.insert(rewrite).inserted { return false }
            ignore(m, .duplicate)
            return true
        }

        // Only one statement-level mutant per range (they are instrumented in a dedicated form and cannot be stacked).
        // Statement removal and statement replacement take priority; emptying the body comes last.
        var statementOwner: [ByteRange: MutationOperator] = [:]
        for m in mutants where m.isStatement && m.operator != .emptyBody { statementOwner[m.region] = statementOwner[m.region] ?? m.operator }
        var keptStatementRanges: Set<ByteRange> = []
        mutants.removeAll { m in
            guard m.isStatement else { return false }
            if m.operator == .emptyBody, statementOwner[m.region] != nil { ignore(m, .sameRangeAsStatement); return true }
            if keptStatementRanges.insert(m.region).inserted { return false }
            ignore(m, .sameRangeAsStatement)
            return true
        }

        // Do not create expression mutants on the same range as a statement removal (such as a statement consisting only of `s.lowercased()`),
        // because a statement switch and an expression switch cannot be stacked on the same range (the statement removal is kept).
        let statementRanges = Set(mutants.filter(\.isStatement).map(\.region))
        mutants.removeAll { m in
            guard !m.isStatement, statementRanges.contains(m.region) else { return false }
            ignore(m, .sameRangeAsStatement)
            return true
        }

        // Narrow by the diff (before the limit)
        var outOfDiff = 0
        if let changedLines {
            let filtered = DiffFilter.filter(mutants, changedLines: changedLines)
            outOfDiff = mutants.count - filtered.count
            mutants = filtered
            ignored = ignored.filter { i in changedLines.contains { $0.contains(i.start.line) } }
        }

        // Limit the number of switches in one expression (to avoid a type-checking blowup).
        // Statement removal switches do not affect expression type checking, so they are not counted.
        let statementMutants = mutants.filter(\.isStatement)
        var limited = ExpressionLimiter.apply(mutants.filter { !$0.isStatement }, limit: options.maxSwitchesPerExpression)
        limited.kept = (limited.kept + statementMutants).sorted { ($0.point.start, $0.region.start) < ($1.point.start, $1.region.start) }
        for m in limited.dropped {
            ignored.append(IgnoredMutant(
                operator: m.operator, file: m.file, enclosingDecl: m.enclosingDecl, point: m.point,
                start: m.start, original: m.original, replacement: m.replacement, reason: .tooManyInExpression))
        }
        mutants = limited.kept.enumerated().map { index, m in
            var m = m
            m.id = index
            return m
        }
        ignored.sort { $0.point < $1.point }
        return GenerationResult(mutants: mutants, ignored: ignored, skippedReason: nil, outOfDiffCount: outOfDiff,
                                warnings: disabled.warnings + keyWarnings)
    }

    static func text(_ bytes: [UInt8], _ range: ByteRange) -> String {
        String(decoding: bytes[range.start..<range.end], as: UTF8.self)
    }

    /// Returns the text in the range with the edits applied (in order from the back).
    static func applyEdits(bytes: [UInt8], region: ByteRange, edits: [Edit]) -> String {
        var out: [UInt8] = []
        var cursor = region.start
        for edit in edits.sorted(by: { ($0.range.start, $0.range.end) < ($1.range.start, $1.range.end) }) {
            precondition(cursor <= edit.range.start && edit.range.end <= region.end, "edits must be disjoint and inside region")
            out.append(contentsOf: bytes[cursor..<edit.range.start])
            out.append(contentsOf: Array(edit.text.utf8))
            cursor = edit.range.end
        }
        out.append(contentsOf: bytes[cursor..<region.end])
        return String(decoding: out, as: UTF8.self)
    }
}

/// Replacement of a range.
struct Edit {
    var range: ByteRange
    var text: String
}

/// A mutant candidate (before the exclusion check).
struct Candidate {
    var op: MutationOperator
    /// The node the candidate originates from (InfixOperatorExpr for a binary operation, TernaryExpr for a ternary, etc.).
    var node: Syntax
    var region: ByteRange
    var point: ByteRange
    var edits: [Edit]
    var original: String
    var replacement: String
    /// The original text that the stable key covers, when that is more than the text of `region`
    /// (`ternary-swap` rewrites the condition, but it is the swap of the two branches that the key names).
    var keyOriginal: String?

    init(op: MutationOperator, node: Syntax, region: ByteRange, point: ByteRange, edits: [Edit], original: String, replacement: String,
         keyOriginal: String? = nil) {
        self.op = op
        self.node = node
        self.region = region
        self.point = point
        self.edits = edits
        self.original = original
        self.replacement = replacement
        self.keyOriginal = keyOriginal
    }
}

extension SyntaxProtocol {
    var trimmedByteRange: ByteRange {
        ByteRange(start: positionAfterSkippingLeadingTrivia.utf8Offset, end: endPositionBeforeTrailingTrivia.utf8Offset)
    }
}

/// Collects mutant candidates from the folded tree.
final class CandidateCollector: SyntaxVisitor {
    let options: GeneratorOptions
    var candidates: [Candidate] = []

    static let binaryReplacements: [String: (String, MutationOperator)] = [
        "==": ("!=", .equalityFlip),
        "!=": ("==", .equalityFlip),
        "<": ("<=", .boundary),
        "<=": ("<", .boundary),
        ">": (">=", .boundary),
        ">=": (">", .boundary),
        "&&": ("||", .logicalConnector),
        "||": ("&&", .logicalConnector),
    ]

    init(options: GeneratorOptions, viewMode: SyntaxTreeViewMode) {
        self.options = options
        super.init(viewMode: viewMode)
    }

    override func visit(_ node: InfixOperatorExprSyntax) -> SyntaxVisitorContinueKind {
        guard let opExpr = node.operator.as(BinaryOperatorExprSyntax.self) else { return .visitChildren }
        let token = opExpr.operator
        guard let (replacement, op) = Self.binaryReplacements[token.text], options.operators.contains(op) else {
            return .visitChildren
        }
        let point = token.trimmedByteRange
        var edits = [Edit(range: point, text: replacement)]
        if op == .logicalConnector {
            // `&&` and `||` have different precedence, so replacing only the operator changes the shape of the tree
            // (changing the outer one of `a || b || c` to `&&` gives `a || (b && c)`). Wrap the operands in parentheses.
            for operand in [node.leftOperand, node.rightOperand] where Self.needsParentheses(operand) {
                let range = operand.trimmedByteRange
                edits.append(Edit(range: ByteRange(start: range.start, end: range.start), text: "("))
                edits.append(Edit(range: ByteRange(start: range.end, end: range.end), text: ")"))
            }
        }
        candidates.append(Candidate(
            op: op, node: Syntax(node), region: node.trimmedByteRange, point: point,
            edits: edits,
            original: token.text, replacement: replacement))
        return .visitChildren
    }

    /// Whether an operand needs to be wrapped in parentheses when the operator is replaced.
    static func needsParentheses(_ expr: ExprSyntax) -> Bool {
        switch expr.kind {
        case .infixOperatorExpr, .ternaryExpr, .asExpr, .isExpr, .tryExpr, .awaitExpr, .sequenceExpr,
             .unsafeExpr, .closureExpr:
            return true
        default:
            return false
        }
    }

    override func visit(_ node: PrefixOperatorExprSyntax) -> SyntaxVisitorContinueKind {
        guard node.operator.text == "!", options.operators.contains(.negationRemoval) else { return .visitChildren }
        let point = node.operator.trimmedByteRange
        // Remove `!` and the whitespace right after it (normally none).
        let removal = ByteRange(start: node.operator.positionAfterSkippingLeadingTrivia.utf8Offset,
                                end: node.expression.positionAfterSkippingLeadingTrivia.utf8Offset)
        candidates.append(Candidate(
            op: .negationRemoval, node: Syntax(node), region: node.trimmedByteRange, point: point,
            edits: [Edit(range: removal, text: "")],
            original: "!", replacement: ""))
        return .visitChildren
    }

    override func visit(_ node: BooleanLiteralExprSyntax) -> SyntaxVisitorContinueKind {
        guard options.operators.contains(.booleanLiteral) else { return .visitChildren }
        let text = node.literal.text
        let replacement = text == "true" ? "false" : "true"
        let range = node.trimmedByteRange
        candidates.append(Candidate(
            op: .booleanLiteral, node: Syntax(node), region: range, point: range,
            edits: [Edit(range: range, text: replacement)],
            original: text, replacement: replacement))
        return .visitChildren
    }

    override func visit(_ node: TernaryExprSyntax) -> SyntaxVisitorContinueKind {
        guard options.operators.contains(.ternarySwap) else { return .visitChildren }
        let thenText = node.thenExpression.trimmedDescription
        let elseText = node.elseExpression.trimmedDescription
        // Not created when both branches have the same text, since that would be equivalent.
        guard thenText != elseText else { return .visitChildren }
        let elseRange = node.elseExpression.trimmedByteRange
        let point = ByteRange(start: node.questionMark.positionAfterSkippingLeadingTrivia.utf8Offset, end: elseRange.end)
        // Embedded as the condition negated: `(isOn(n) ? (!(c)) : (c)) ? a : b`. The condition is evaluated once, so this
        // is the swap of the branches. Wrapping the whole expression in a switch instead would put two copies of the
        // ternary into the branches of another ternary, where the types of `a` and `b` are no longer unified by the
        // context (`return round ? Circle() : Square()` as `any Shape`; `c ? v : nil`): it would not compile, even
        // with all mutants off. It also keeps the instrumented expression short.
        let condition = node.condition
        let conditionRange = condition.trimmedByteRange
        candidates.append(Candidate(
            op: .ternarySwap, node: Syntax(condition), region: conditionRange, point: point,
            edits: [Edit(range: ByteRange(start: conditionRange.start, end: conditionRange.start), text: "!("),
                    Edit(range: ByteRange(start: conditionRange.end, end: conditionRange.end), text: ")")],
            original: "? \(thenText) : \(elseText)", replacement: "? \(elseText) : \(thenText)",
            keyOriginal: node.trimmedDescription))
        return .visitChildren
    }
}

/// Finds operator sequences (`SequenceExprSyntax`) whose precedence cannot be determined.
struct UnfoldableSequenceFinder {
    let table: OperatorTable

    func find(in tree: SourceFileSyntax) -> [ByteRange] {
        let visitor = Visitor(table: table)
        visitor.walk(tree)
        return visitor.ranges
    }

    private final class Visitor: SyntaxVisitor {
        let table: OperatorTable
        var ranges: [ByteRange] = []

        init(table: OperatorTable) {
            self.table = table
            super.init(viewMode: .sourceAccurate)
        }

        override func visit(_ node: SequenceExprSyntax) -> SyntaxVisitorContinueKind {
            do {
                _ = try table.foldSingle(node)
            } catch {
                ranges.append(node.trimmedByteRange)
            }
            return .visitChildren
        }
    }
}

/// Disable comments.
///
/// - `// xcmutate:disable-next-line [operator...]`: the next line
/// - `// xcmutate:disable-line [operator...]`: that line
/// - `// xcmutate:disable [operator...]` to `// xcmutate:enable [operator...]`: the lines in between (inclusive)
///
/// Writing operator names (such as `boundary`; separated by spaces or commas) disables only those operators. With no names, all are disabled.
/// A ` -- reason` may follow the names. An unknown name is not ignored but reported as a warning, and that directive disables nothing
/// (so that a typo does not silently disable an unintended range).
public struct DisableComments: Sendable {
    /// Prefix inside the comment. To rename the tool, change only this.
    public static let marker = ToolNaming.commentMarker

    private struct Rule { var all = false; var operators: Set<MutationOperator> = [] }
    private var lines: [Int: Rule] = [:]
    public private(set) var warnings: [GenerationWarning] = []

    /// The lines on which a comment holds the marker (`// xcmutate:…`). The same text in a string literal
    /// (`let hint = "// xcmutate:disable"`) is not a directive.
    static func commentLines(in tree: SourceFileSyntax, converter: SourceLocationConverter, marker: String = DisableComments.marker) -> Set<Int> {
        var lines: Set<Int> = []
        for token in tree.tokens(viewMode: .sourceAccurate) {
            var offset = token.position.utf8Offset
            func scan(_ trivia: Trivia) {
                for piece in trivia {
                    let length = piece.sourceLength.utf8Length
                    switch piece {
                    case let .lineComment(text), let .blockComment(text), let .docLineComment(text), let .docBlockComment(text):
                        if text.contains(marker) {
                            let first = converter.location(for: AbsolutePosition(utf8Offset: offset)).line
                            let last = converter.location(for: AbsolutePosition(utf8Offset: offset + max(length - 1, 0))).line
                            lines.formUnion(first...max(first, last))
                        }
                    default:
                        break
                    }
                    offset += length
                }
            }
            scan(token.leadingTrivia)
            offset += token.trimmedLength.utf8Length
            scan(token.trailingTrivia)
        }
        return lines
    }

    /// - Parameter commentLines: when given, only these lines can hold a directive (`commentLines(in:converter:)`).
    public init(source: String, commentLines: Set<Int>? = nil) {
        var block = Rule()
        var next: Rule?
        var lineNumber = 0
        func merge(_ rule: inout Rule, _ other: Rule) {
            rule.all = rule.all || other.all
            rule.operators.formUnion(other.operators)
        }
        // `isNewline` and not "\n": with CRLF line endings "\r\n" is one `Character`, and nothing would be split
        for line in source.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            lineNumber += 1
            var here = block
            if let pending = next { merge(&here, pending) }
            next = nil
            if commentLines?.contains(lineNumber) != false, let directive = Self.parse(line, lineNumber: lineNumber, warnings: &warnings) {
                // If names were written but none of them is known, disable nothing
                let rule = Rule(all: directive.operators.isEmpty && !directive.hadNames, operators: directive.operators)
                switch directive.kind {
                case "disable-next-line":
                    next = rule
                case "disable-line":
                    merge(&here, rule)
                case "disable":
                    merge(&block, rule)
                    merge(&here, rule)
                case "enable":
                    if directive.hadNames { block.operators.subtract(directive.operators) } else { block = Rule() }
                default:
                    warnings.append(GenerationWarning(line: lineNumber, message: "unknown directive `\(Self.marker)\(directive.kind)` (known: disable, enable, disable-line, disable-next-line)"))
                }
            }
            if here.all || !here.operators.isEmpty { lines[lineNumber] = here }
        }
    }

    private static func parse(_ line: Substring, lineNumber: Int, warnings: inout [GenerationWarning])
        -> (kind: String, operators: Set<MutationOperator>, hadNames: Bool)? {
        guard let range = line.firstRange(of: marker) else { return nil }
        var rest = line[range.upperBound...]
        if let reason = rest.firstRange(of: "--") { rest = rest[..<reason.lowerBound] }
        if let close = rest.firstRange(of: "*/") { rest = rest[..<close.lowerBound] }
        let separators: Set<Character> = [" ", "\t", ","]
        let words: [String] = rest.split(whereSeparator: { separators.contains($0) }).map { String($0) }
        guard let kind = words.first else { return nil }
        var operators: Set<MutationOperator> = []
        for name in words.dropFirst() {
            if let op = MutationOperator(rawValue: name) {
                operators.insert(op)
            } else {
                warnings.append(GenerationWarning(line: lineNumber, message: "unknown operator `\(name)` in `\(marker)\(kind)`; it disables nothing (put a reason after ` -- `)"))
            }
        }
        return (kind, operators, words.count > 1)
    }

    public func isDisabled(line: Int, operator op: MutationOperator) -> Bool {
        guard let rule = lines[line] else { return false }
        return rule.all || rule.operators.contains(op)
    }
}

/// Limits the number of switches in one expression (the outermost expression of a nest).
enum ExpressionLimiter {
    /// For each outer expression (a range not contained in another range), narrows the switches down to `limit`.
    /// When over the limit, picks one at a time from each operator kind in turn (so that the kinds stay balanced),
    /// and within the same kind picks shorter ranges first (inner comparisons and the like, which find test gaps more easily).
    static func apply(_ mutants: [Mutant], limit: Int) -> (kept: [Mutant], dropped: [Mutant]) {
        guard limit > 0 else { return ([], mutants) }
        let sorted = mutants.sorted { $0.region < $1.region }
        var groups: [[Mutant]] = []
        var currentRoot: ByteRange?
        for m in sorted {
            if let root = currentRoot, root.contains(m.region) {
                groups[groups.count - 1].append(m)
            } else {
                currentRoot = m.region
                groups.append([m])
            }
        }
        var kept: [Mutant] = []
        var dropped: [Mutant] = []
        for group in groups {
            guard group.count > limit else { kept += group; continue }
            var byOperator: [MutationOperator: [Mutant]] = [:]
            for m in group { byOperator[m.operator, default: []].append(m) }
            var queues = byOperator.keys.sorted { $0.rawValue < $1.rawValue }.map { op in
                byOperator[op]!.sorted { ($0.region.length, $0.point.start) < ($1.region.length, $1.point.start) }
            }
            var chosen: [Mutant] = []
            while chosen.count < limit, queues.contains(where: { !$0.isEmpty }) {
                for index in queues.indices where chosen.count < limit && !queues[index].isEmpty {
                    chosen.append(queues[index].removeFirst())
                }
            }
            let chosenIDs = Set(chosen.map(\.key))
            kept += chosen
            dropped += group.filter { !chosenIDs.contains($0.key) }
        }
        kept.sort { ($0.point.start, $0.region.start) < ($1.point.start, $1.region.start) }
        dropped.sort { $0.point.start < $1.point.start }
        return (kept, dropped)
    }
}
