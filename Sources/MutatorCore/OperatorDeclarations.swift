import SwiftParser
import SwiftSyntax

/// What the generator needs to know about the files of the project other than the one it mutates.
///
/// - Functions declared `-> Never` in any file: a call to one must not be wrapped for removal, or the function that
///   ends with it no longer returns on every path and does not compile even with all mutants off.
/// - Result builder types (`@resultBuilder`) whose name does not end in `Builder`: statements in their bodies are
///   not wrapped in `if`, which the builder may not accept.
public struct ProjectDeclarations: Sendable, Equatable {
    public var neverReturningNames: Set<String> = []
    public var resultBuilderNames: Set<String> = []

    public init() {}

    public static func scan(sources: [String]) -> ProjectDeclarations {
        var result = ProjectDeclarations()
        for source in sources where source.contains("Never") || source.contains("resultBuilder") {
            let finder = ProjectDeclarationFinder(viewMode: .sourceAccurate)
            finder.walk(Parser.parse(source: source))
            result.neverReturningNames.formUnion(finder.neverReturningNames)
            result.resultBuilderNames.formUnion(finder.resultBuilderNames)
        }
        return result
    }

    /// Adds the declarations to the options (the lists the user configured are kept).
    public func apply(to options: inout GeneratorOptions) {
        options.neverReturningNames.formUnion(neverReturningNames)
        options.resultBuilderNames.formUnion(resultBuilderNames)
    }
}

final class ProjectDeclarationFinder: SyntaxVisitor {
    var neverReturningNames: Set<String> = []
    var resultBuilderNames: Set<String> = []

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        if let type = node.signature.returnClause?.type.trimmedDescription, type == "Never" || type == "Swift.Never" {
            neverReturningNames.insert(node.name.text)
        }
        return .visitChildren
    }

    private func note(_ node: some WithAttributesSyntax, name: String) {
        if ExclusionRules.hasAttribute(Syntax(node), in: ["resultBuilder", "_functionBuilder"]) { resultBuilderNames.insert(name) }
    }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind { note(node, name: node.name.text); return .visitChildren }
    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind { note(node, name: node.name.text); return .visitChildren }
    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind { note(node, name: node.name.text); return .visitChildren }
    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind { note(node, name: node.name.text); return .visitChildren }
}

/// Extracts only the `precedencegroup` and `operator` declarations from multiple files.
///
/// When the precedence group of a custom operator is declared in another file (of the same module), a single file is not enough
/// to fold the expression, and no mutants can be created for it (`unfoldable-operators`). Collecting the declarations from the
/// files of the target module and passing them to `GeneratorOptions.extraOperatorDeclarations` makes folding possible.
public enum OperatorDeclarations {
    public static func extract(from sources: [String]) -> String {
        var decls: [String] = []
        for source in sources where source.contains("operator") || source.contains("precedencegroup") {
            let tree = Parser.parse(source: source)
            for item in tree.statements {
                if let d = item.item.as(PrecedenceGroupDeclSyntax.self) { decls.append(d.trimmedDescription) }
                if let d = item.item.as(OperatorDeclSyntax.self) { decls.append(d.trimmedDescription) }
            }
        }
        return decls.joined(separator: "\n")
    }
}
