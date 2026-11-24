import SwiftParser
import SwiftSyntax

/// Puts the mutated expression on one line.
///
/// The mutated branch of a switch is a copy of the original expression, so if the original spans several lines, inserting it as is
/// shifts the following line numbers. To keep line numbers identical to the original source (so that mutants can be
/// identified from compiler diagnostics), newlines and comments are replaced with spaces and `;` is inserted at statement boundaries.
/// The one-line result is re-parsed to confirm that the token sequence is unchanged. If that cannot be confirmed, `nil`.
enum Flattener {
    static func flatten(_ text: String) -> String? {
        // By bytes: in a `String`, "\r\n" is one `Character` that equals neither "\n" nor "\r", so a file with
        // CRLF line endings would look as if it had no line break at all
        guard Self.hasLineBreak(text) else { return text }

        let tree = Parser.parse(source: text)
        guard !tree.hasError else { return nil }

        let boundaries = StatementBoundaryFinder.find(in: tree)
        var out = ""
        let tokens = Array(tree.tokens(viewMode: .sourceAccurate))
        for (index, token) in tokens.enumerated() {
            if index > 0 {
                let separator = normalize(token.leadingTrivia)
                let needsSemicolon = boundaries.contains(token.positionAfterSkippingLeadingTrivia.utf8Offset)
                if needsSemicolon {
                    out += "; "
                } else {
                    out += separator
                }
            }
            if token.tokenKind == .endOfFile { break }
            out += token.text
            if index + 1 < tokens.count {
                out += normalize(token.trailingTrivia)
            }
        }
        guard !Self.hasLineBreak(out) else { return nil }

        // Confirm that the one-line result yields the same token sequence (excluding the inserted `;`).
        let reparsed = Parser.parse(source: out)
        guard !reparsed.hasError else { return nil }
        let before = significantTokens(tree)
        let after = significantTokens(reparsed)
        guard before == after else { return nil }
        return out
    }

    static func hasLineBreak(_ text: String) -> Bool {
        text.utf8.contains { $0 == UInt8(ascii: "\n") || $0 == UInt8(ascii: "\r") }
    }

    private static func normalize(_ trivia: Trivia) -> String {
        if trivia.isEmpty { return "" }
        var onlyHorizontalSpace = true
        for piece in trivia {
            switch piece {
            case .spaces, .tabs: continue
            default: onlyHorizontalSpace = false
            }
        }
        return onlyHorizontalSpace ? trivia.description : " "
    }

    private static func significantTokens(_ tree: SourceFileSyntax) -> [String] {
        tree.tokens(viewMode: .sourceAccurate)
            .filter { $0.tokenKind != .semicolon && $0.tokenKind != .endOfFile }
            .map(\.text)
    }
}

/// In a statement list, the positions of the first token of the second and later statements (where the previous statement does not end with `;`).
private final class StatementBoundaryFinder: SyntaxVisitor {
    var positions: Set<Int> = []

    static func find(in tree: SourceFileSyntax) -> Set<Int> {
        let finder = StatementBoundaryFinder(viewMode: .sourceAccurate)
        finder.walk(tree)
        return finder.positions
    }

    override func visit(_ node: CodeBlockItemListSyntax) -> SyntaxVisitorContinueKind {
        var previous: CodeBlockItemSyntax?
        for item in node {
            if let previous, previous.semicolon == nil {
                positions.insert(item.positionAfterSkippingLeadingTrivia.utf8Offset)
            }
            previous = item
        }
        return .visitChildren
    }

    override func visit(_ node: MemberBlockItemListSyntax) -> SyntaxVisitorContinueKind {
        var previous: MemberBlockItemSyntax?
        for item in node {
            if let previous, previous.semicolon == nil {
                positions.insert(item.positionAfterSkippingLeadingTrivia.utf8Offset)
            }
            previous = item
        }
        return .visitChildren
    }
}
