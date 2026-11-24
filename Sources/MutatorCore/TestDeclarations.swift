import SwiftParser
import SwiftSyntax

/// What a Swift file declares, as far as reusing results between runs (`--reuse`) needs to know: which types a
/// test identifier such as `CartTests/testTotal()` can refer to, and whether the file holds tests at all.
public enum TestImports {
    static let frameworks: Set<String> = ["XCTest", "Testing", "Quick", "Nimble"]

    /// Whether the file imports a test framework or imports a module `@testable`: by its import declarations, not by
    /// its text (a product file that holds `import XCTest` in a multi-line string, a template for a test file, is not test code).
    public static func importsTestFramework(_ source: String) -> Bool {
        // Most files do not mention any of this; they are not parsed
        guard source.contains("@testable") || frameworks.contains(where: { source.contains($0) }) else { return false }
        final class Visitor: SyntaxVisitor {
            var found = false
            override func visit(_ node: ImportDeclSyntax) -> SyntaxVisitorContinueKind {
                if let first = node.path.first?.name.text, TestImports.frameworks.contains(first) { found = true }
                for element in node.attributes {
                    if case let .attribute(attribute) = element, attribute.attributeName.trimmedDescription == "testable" { found = true }
                }
                return .skipChildren
            }
        }
        let visitor = Visitor(viewMode: .sourceAccurate)
        visitor.walk(Parser.parse(source: source))
        return visitor.found
    }
}

public struct TestDeclarations: Sendable, Equatable {
    /// Types declared or extended in the file (at any nesting level) with the names of their inheritance clauses.
    public var types: [String: Set<String>] = [:]
    /// Functions at file level that are marked `@Test`.
    public var topLevelTests: Set<String> = []
    /// Whether the file declares tests: a `@Test` function, a `@Suite` type, or a method named `test…` in a class.
    public var declaresTests = false

    public static func scan(source: String) -> TestDeclarations {
        final class Visitor: SyntaxVisitor {
            var result = TestDeclarations()
            var classDepth = 0

            func attributeNames(_ attributes: AttributeListSyntax) -> [String] {
                attributes.compactMap { element -> String? in
                    guard case let .attribute(attribute) = element else { return nil }
                    return attribute.attributeName.trimmedDescription
                }
            }

            func add(_ name: String, _ inheritance: InheritanceClauseSyntax?, _ attributes: AttributeListSyntax) {
                let inherited = Set((inheritance?.inheritedTypes ?? []).map { $0.type.trimmedDescription.split(separator: ".").last.map(String.init) ?? "" })
                result.types[name, default: []].formUnion(inherited)
                if attributeNames(attributes).contains(where: { $0 == "Suite" || $0 == "Testing.Suite" }) { result.declaresTests = true }
            }

            override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
                add(node.name.text, node.inheritanceClause, node.attributes)
                classDepth += 1
                return .visitChildren
            }
            override func visitPost(_ node: ClassDeclSyntax) { classDepth -= 1 }
            override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind { add(node.name.text, node.inheritanceClause, node.attributes); return .visitChildren }
            override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind { add(node.name.text, node.inheritanceClause, node.attributes); return .visitChildren }
            override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind { add(node.name.text, node.inheritanceClause, node.attributes); return .visitChildren }
            override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
                // `extension Outer.Inner` extends `Inner`; an extension of a class may hold test methods too
                let name = node.extendedType.trimmedDescription.split(separator: ".").last.map(String.init) ?? ""
                add(name, node.inheritanceClause, node.attributes)
                classDepth += 1
                return .visitChildren
            }
            override func visitPost(_ node: ExtensionDeclSyntax) { classDepth -= 1 }

            override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
                let isTest = attributeNames(node.attributes).contains { $0 == "Test" || $0 == "Testing.Test" }
                if isTest {
                    result.declaresTests = true
                    if node.parent?.parent?.parent?.is(SourceFileSyntax.self) == true { result.topLevelTests.insert(node.name.text) }
                }
                if classDepth > 0, node.name.text.hasPrefix("test") { result.declaresTests = true }
                return .visitChildren
            }
        }
        let visitor = Visitor(viewMode: .sourceAccurate)
        visitor.walk(Parser.parse(source: source))
        return visitor.result
    }

    /// The tokens that start on the given lines, joined by a space: the text of a declaration without comments,
    /// line breaks and indentation, so that reformatting it does not look like a change.
    public static func tokenText(source: String, lines: LineSpan) -> String {
        let tree = Parser.parse(source: source)
        let converter = SourceLocationConverter(fileName: "", tree: tree)
        var parts: [String] = []
        for token in tree.tokens(viewMode: .sourceAccurate) {
            let line = converter.location(for: token.positionAfterSkippingLeadingTrivia).line
            if line > lines.end { break }
            if line >= lines.start, !token.text.isEmpty { parts.append(token.text) }
        }
        return parts.joined(separator: " ")
    }
}
