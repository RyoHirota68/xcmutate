import SwiftParser
import SwiftSyntax

/// Result of the static verification of the instrumented text.
public struct VerificationResult: Codable, Hashable, Sendable {
    /// IDs that were expected but never appeared (they become phantom mutants).
    public var missingIDs: [Int]
    /// IDs that appeared two or more times.
    public var duplicatedIDs: [Int]
    /// IDs that appeared although they were not expected.
    public var unexpectedIDs: [Int]
    /// The instrumented text cannot be parsed (only when the original text can be parsed).
    public var hasSyntaxError: Bool
    /// The number of lines before the helper does not match the original source (compiler diagnostic line numbers would shift).
    public var lineCountChanged: Bool
    /// Number of helper declarations (should be 1 if there are mutants, 0 otherwise).
    public var helperCount: Int
    /// The number of helpers differs from the expectation (1 if there are mutants, 0 otherwise).
    public var helperCountMismatch: Bool

    public var isValid: Bool {
        missingIDs.isEmpty && duplicatedIDs.isEmpty && unexpectedIDs.isEmpty
            && !hasSyntaxError && !lineCountChanged && !helperCountMismatch
    }

    public var problems: [String] {
        var result: [String] = []
        if !missingIDs.isEmpty { result.append("missing switch IDs: \(missingIDs)") }
        if !duplicatedIDs.isEmpty { result.append("duplicated switch IDs: \(duplicatedIDs)") }
        if !unexpectedIDs.isEmpty { result.append("unexpected switch IDs: \(unexpectedIDs)") }
        if hasSyntaxError { result.append("instrumented source has syntax errors") }
        if lineCountChanged { result.append("line count before the helper changed") }
        if helperCountMismatch { result.append("unexpected number of helper declarations: \(helperCount)") }
        return result
    }
}

public enum InstrumentationVerifier {
    /// Builds the expected IDs and counts from the list of mutants and verifies.
    public static func verify(original: String, instrumented: String, mutants: [Mutant]) -> VerificationResult {
        var multiplicity: [Int: Int] = [:]
        for m in mutants { if let offsets = m.guardOffsets { multiplicity[m.id] = offsets.count } }
        return verify(original: original, instrumented: instrumented, expectedIDs: mutants.map(\.id), multiplicity: multiplicity)
    }

    /// Checks that the instrumented text contains the switch for each expected ID exactly once, that there are no syntax errors,
    /// and that line numbers are preserved.
    ///
    /// Switches are counted using the syntax tree (calls of `__xcmutate.isOn(<integer literal>)`).
    /// The same string inside string literals or comments is not counted.
    ///
    /// - Parameter multiplicity: IDs that should appear several times rather than once, with their counts (`switch-case-removal`
    ///   appears once per pattern).
    public static func verify(original: String, instrumented: String, expectedIDs: [Int], multiplicity: [Int: Int] = [:]) -> VerificationResult {
        let tree = Parser.parse(source: instrumented)
        let counter = SwitchCounter(viewMode: .sourceAccurate)
        counter.walk(tree)

        var missing: [Int] = []
        var duplicated: [Int] = []
        let expected = Set(expectedIDs)
        for id in expectedIDs.sorted() {
            let count = counter.counts[id, default: 0]
            if count == 0 { missing.append(id) } else if count != multiplicity[id, default: 1] { duplicated.append(id) }
        }
        let unexpected = counter.counts.keys.filter { !expected.contains($0) }.sorted()

        let lineCountChanged: Bool
        if expectedIDs.isEmpty {
            lineCountChanged = instrumented != original
        } else if let markerOffset = firstOffset(of: Instrumenter.helperMarker, in: instrumented) {
            let body = Array(instrumented.utf8)[..<markerOffset]
            let originalLines = original.utf8.reduce(0) { $1 == UInt8(ascii: "\n") ? $0 + 1 : $0 }
            var bodyLines = body.reduce(0) { $1 == UInt8(ascii: "\n") ? $0 + 1 : $0 }
            // If the original source does not end with a newline, one newline has been appended at the end.
            if let last = original.utf8.last, last != UInt8(ascii: "\n"), last != UInt8(ascii: "\r") { bodyLines -= 1 }
            lineCountChanged = originalLines != bodyLines
        } else {
            lineCountChanged = true
        }

        return VerificationResult(
            missingIDs: missing, duplicatedIDs: duplicated, unexpectedIDs: unexpected,
            hasSyntaxError: tree.hasError && !Parser.parse(source: original).hasError, lineCountChanged: lineCountChanged,
            helperCount: counter.helperCount,
            helperCountMismatch: counter.helperCount != (expectedIDs.isEmpty ? 0 : 1))
    }
}

/// The UTF-8 byte position where `needle` first appears.
func firstOffset(of needle: String, in haystack: String) -> Int? {
    let h = Array(haystack.utf8)
    let n = Array(needle.utf8)
    guard !n.isEmpty, h.count >= n.count else { return nil }
    var i = 0
    while i <= h.count - n.count {
        if h[i] == n[0], Array(h[i..<(i + n.count)]) == n { return i }
        i += 1
    }
    return nil
}

private final class SwitchCounter: SyntaxVisitor {
    var counts: [Int: Int] = [:]
    var helperCount = 0

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        if let member = node.calledExpression.as(MemberAccessExprSyntax.self),
           member.declName.baseName.text == "isOn",
           member.base?.as(DeclReferenceExprSyntax.self)?.baseName.text == Instrumenter.helperTypeName,
           node.arguments.count == 1,
           let literal = node.arguments.first?.expression.as(IntegerLiteralExprSyntax.self),
           let id = Int(literal.literal.text) {
            counts[id, default: 0] += 1
        }
        return .visitChildren
    }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        if node.name.text == Instrumenter.helperTypeName { helperCount += 1 }
        return .visitChildren
    }
}
