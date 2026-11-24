import Foundation
@testable import MutatorCore
import SwiftParser
import SwiftSyntax
import Testing

/// The stable key of a mutant (`accept`, `--baseline-report`, `--only` and `--reuse` match mutants by it).
/// and the metamorphic checks (the same code written in another way gives the same keys).
@Suite struct StableKeyTests {
    static let all = GeneratorOptions(operators: Set(MutationOperator.allCases))

    private func mutants(_ source: String, file: String = "K.swift") -> [Mutant] {
        MutantGenerator(options: Self.all).generate(source: source, filePath: file).mutants
    }

    /// Key → what the mutant is, without its position.
    private func identities(_ source: String) -> [String: String] {
        var result: [String: String] = [:]
        for mutant in mutants(source) {
            result[mutant.key] = "\(mutant.operator.rawValue) | \(mutant.enclosingDecl) | \(StableKey.normalized(mutant.originalExpression)) | \(mutant.mutatedExpression)"
        }
        return result
    }

    // MARK: The hash

    @Test func fnvHashValues() {
        #expect(StableKey.fnv1a64("") == 0xcbf2_9ce4_8422_2325)
        #expect(StableKey.fnv1a64("a") == 0xaf63_dc4c_8601_ec8c)
        #expect("abc".leftPad(5) == "00abc")
        #expect("abcde".leftPad(5) == "abcde")
        #expect("abcdef".leftPad(5) == "abcdef")
    }

    @Test func keysHaveFourPartsAndASixteenDigitHash() throws {
        let key = try #require(mutants("func f(_ a: Int) -> Bool { a > 1 }\n").first { $0.operator == .boundary }).key
        let parts = key.components(separatedBy: "::")
        #expect(parts.count == 4)
        #expect(parts[0] == "K.swift")
        #expect(parts[1] == "f(_:)")
        #expect(parts[2] == "boundary")
        #expect(parts[3].count == 16)
        let hash = parts[3]
        #expect(hash.allSatisfy { $0.isHexDigit })
    }

    // MARK: What the key depends on

    /// Two statements of the same form in one function: different keys, and no `#2`.
    @Test func samePatternAtTwoPlacesOfOneFunctionHasTwoKeys() {
        let keys = mutants("""
        func f(_ a: Int, _ b: Int) -> Int {
            if a > b { return 1 }
            if a > b { return 2 }
            return 0
        }

        """).filter { $0.operator == .boundary }.map(\.key)
        #expect(keys.count == 2)
        #expect(Set(keys).count == 2)
        #expect(keys.allSatisfy { !$0.contains("#") })
    }

    /// The key covers the expression that is rewritten, also when the mutated text is a constant.
    @Test func theKeyChangesWithTheOriginalExpression() throws {
        func keys(_ condition: String) -> [MutationOperator: [String]] {
            Dictionary(grouping: mutants("func withTax(_ amount: Int) -> Int {\n    if \(condition) { return 0 }\n    return amount * 11 / 10\n}\n")
                .filter { $0.start.line == 2 }, by: \.operator).mapValues { $0.map(\.key) }
        }
        let before = keys("amount <= 0")
        let after = keys("amount <= 100")
        let conditionConstant = try #require(before[.conditionConstant])
        #expect(!conditionConstant.isEmpty)
        #expect(Set(conditionConstant).isDisjoint(with: after[.conditionConstant] ?? []))
        #expect(Set(before[.boundary] ?? []).isDisjoint(with: after[.boundary] ?? []))

        // The operands of a logical expression swapped: `hasDigit -> true` must not take the key of `hasLetter -> true`
        func operands(_ expression: String) -> [String: String] {
            var result: [String: String] = [:]
            for mutant in mutants("func strong(_ p: String, _ hasDigit: Bool, _ hasLetter: Bool) -> Bool {\n    return \(expression)\n}\n")
            where mutant.operator == .operandRemoval {
                result[mutant.key] = mutant.original
            }
            return result
        }
        let first = operands("p.count >= 8 && hasDigit && hasLetter")
        let second = operands("p.utf8.count > 12 && hasLetter && hasDigit")
        #expect(first.count >= 3)
        for (key, original) in first {
            if let other = second[key] { #expect(other == original, "the key of `\(original)` now names `\(other)`") }
        }
    }

    /// Overloads with the same labels have keys that do not depend on their order.
    @Test func overloadsWithTheSameLabelsKeepTheirKeysWhenReordered() {
        let int = "func g(_ a: Int) -> Bool { a > 1 }\n"
        let double = "func g(_ a: Double) -> Bool { a > 1 }\n"
        let one = identities(int + double)
        let other = identities(double + int)
        #expect(one == other)
        #expect(one.keys.allSatisfy { !$0.contains("#") })
        // The same in extensions that differ in their `where` clause
        let a = "extension Array where Element == Int { func big() -> Bool { count > 1 } }\n"
        let b = "extension Array where Element == String { func big() -> Bool { count > 1 } }\n"
        #expect(identities(a + b) == identities(b + a))
        #expect(identities(a + b).keys.allSatisfy { !$0.contains("#") })
        // An overload added before a function does not move the function's keys
        #expect(Set(identities(int).keys).isSubset(of: identities(double + int).keys))
    }

    /// Identical declarations (the branches of an `#if`) are told apart by order: the only use of `#2`.
    @Test func identicalDeclarationsGetANumber() {
        let keys = mutants("""
        #if DEBUG
        func f(_ a: Int) -> Bool { a > 1 }
        #else
        func f(_ a: Int) -> Bool { a > 1 }
        #endif

        """).filter { $0.operator == .boundary }.map(\.key)
        #expect(keys.count == 2)
        #expect(keys[1] == keys[0] + "#2")
    }

    /// Top-level code: a declaration added before a statement does not change the statement's keys.
    @Test func topLevelKeysDoNotDependOnWhatComesBefore() {
        let source = "let a = 3\nif a > 1 { print(\"x\") }\nfunc f(_ x: Int) -> Bool { x > 1 }\n"
        let before = identities(source)
        let after = identities("func unrelated() {}\nlet zero = 0\n" + source + "func alsoUnrelated() {}\n")
        #expect(!before.isEmpty)
        for (key, identity) in before { #expect(after[key] == identity, "\(key)") }
    }

    /// A statement added before the mutated one, in the same function, does change the key (documented).
    @Test func aStatementAddedBeforeChangesTheKey() {
        let before = Set(identities("func f(_ a: Int) -> Bool {\n    return a > 1\n}\n").keys)
        let after = Set(identities("func f(_ a: Int) -> Bool {\n    print(a)\n    return a > 1\n}\n").keys)
        #expect(before.isDisjoint(with: after))
    }

    /// The enclosing declaration of each kind is named in the key.
    @Test func enclosingDeclarationsOfEveryKindAreNamed() {
        let source = """
        enum Kind { case a; var title: Bool { get { 1 > 0 } } }
        actor Counter { var n = 0; func bump(_ by: Int) -> Bool { by > 0 } }
        protocol P { }
        extension P { func ok(_ x: Int) -> Bool { x > 0 } }
        struct Box { subscript(_ i: Int, default d: Int) -> Bool { i > d }; init?(_ x: Int) { if x > 0 { return nil } }; var stored = 1 > 0 }
        class C { deinit { } ; func f(a x: Int, _ y: Int) -> Bool { x > y } }

        """
        let declarations = Set(mutants(source).filter { $0.operator == .boundary }.map(\.enclosingDecl))
        #expect(declarations == ["Kind.title.get", "Counter.bump(_:)", "extension P.ok(_:)", "Box.subscript(_:default:)", "Box.init?(_:)", "Box.stored", "C.f(a:_:)"])
    }

    // MARK: Metamorphic checks on real files

    /// The files the transformations are applied to: the fixtures and the sources of the tool's core.
    static let corpus: [(path: String, source: String)] = {
        var files: [(String, String)] = []
        for directory in ["Fixtures/SampleApp/SampleApp", "Fixtures/LogicKit/Sources", "Fixtures/SampleApp/Packages", "Sources/MutatorCore"] {
            let root = repositoryRoot.appendingPathComponent(directory)
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                if let source = try? String(contentsOf: url, encoding: .utf8) { files.append((url.path, source)) }
            }
        }
        return files.sorted { $0.0 < $1.0 }
    }()

    /// Byte offsets of the starts of lines that begin a token (not inside a multi-line string literal or a comment).
    private func lineStarts(_ source: String) -> [Int] {
        var offsets: [Int] = []
        for token in Parser.parse(source: source).tokens(viewMode: .sourceAccurate) {
            var offset = token.position.utf8Offset
            var lastNewlineEnd: Int?
            for piece in token.leadingTrivia {
                offset += piece.sourceLength.utf8Length
                if piece.isNewline { lastNewlineEnd = offset }
            }
            if let lastNewlineEnd { offsets.append(lastNewlineEnd) }
        }
        return offsets
    }

    private func inserting(_ text: String, at offsets: [Int], into source: String) -> String {
        var bytes = Array(source.utf8)
        for offset in offsets.sorted(by: >) { bytes.insert(contentsOf: Array(text.utf8), at: offset) }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Every seventh line start (a fixed choice, so that failures can be reproduced).
    private func some(_ offsets: [Int]) -> [Int] {
        offsets.enumerated().filter { $0.offset % 7 == 3 }.map(\.element)
    }

    @Test(.timeLimit(.minutes(10)))
    func keysSurviveEditsThatChangeNoCode() {
        #expect(Self.corpus.count > 30)
        var checked = 0
        for (path, source) in Self.corpus {
            let original = identities(source)
            guard !original.isEmpty else { continue }
            checked += 1
            let starts = lineStarts(source)
            let variants: [(String, String)] = [
                ("a comment line at the top", "// A comment line that was not there before. 🎌\n" + source),
                ("blank lines", inserting("\n", at: some(starts), into: source)),
                ("comment lines", inserting("// コメント 🎌 a line comment\n", at: some(starts), into: source)),
                ("every line indented", source.split(separator: "\n", omittingEmptySubsequences: false)
                    .map { $0.isEmpty ? "" : "    " + $0 }.joined(separator: "\n")),
            ]
            for (name, variant) in variants {
                #expect(!Parser.parse(source: variant).hasError, "\(name) broke \(path)")
                // Every key still names the same mutant. (A line inserted after a `disable-next-line` comment makes
                // the comment apply to the inserted line, so a mutant can appear; none may change or disappear.)
                let changed = identities(variant)
                for (key, identity) in original {
                    #expect(changed[key] == identity, "\(name): \(key) changed or disappeared in \(path)")
                }
                #expect(changed.count - original.count <= source.components(separatedBy: "disable-next-line").count - 1, "\(name): new keys in \(path)")
            }
        }
        #expect(checked > 20)
    }

    @Test(.timeLimit(.minutes(10)))
    func keysSurviveDeclarationsAddedOrReordered() {
        for (path, source) in Self.corpus {
            let original = identities(source)
            guard !original.isEmpty else { continue }
            let tree = Parser.parse(source: source)

            // Unrelated functions before and after everything else
            let around = identities("func unrelatedBefore() {}\n" + source + "\nfunc unrelatedAfter() {}\n")
            for (key, identity) in original { #expect(around[key] == identity, "a function added around the file changed \(key) in \(path)") }

            // An unrelated method at the start of every type and extension
            let bodies = MemberBlockFinder.find(in: tree)
            let withMembers = identities(inserting(" func unrelatedMember() {} ;", at: bodies.map(\.afterBrace), into: source))
            for (key, identity) in original { #expect(withMembers[key] == identity, "a member added to a type changed \(key) in \(path)") }

            // Before every function with parameters: another function of the same name and labels, another first type
            let overloads = FunctionFinder.find(in: tree)
            var bytes = Array(source.utf8)
            for function in overloads.sorted(by: { $0.start > $1.start }) {
                bytes.insert(contentsOf: Array(function.overload.utf8), at: function.start)
            }
            let withOverloads = identities(String(decoding: bytes, as: UTF8.self))
            for (key, identity) in original { #expect(withOverloads[key] == identity, "an overload added before a function changed \(key) in \(path)") }

            // Two neighbouring members swapped, in every type that has two
            var swapped = Array(source.utf8)
            for body in bodies.sorted(by: { $0.afterBrace > $1.afterBrace }) {
                guard let pair = body.firstTwoMembers else { continue }
                let first = Array(swapped[pair.first.start..<pair.first.end])
                let second = Array(swapped[pair.second.start..<pair.second.end])
                swapped.replaceSubrange(pair.second.start..<pair.second.end, with: first)
                swapped.replaceSubrange(pair.first.start..<pair.first.end, with: second)
            }
            let reordered = String(decoding: swapped, as: UTF8.self)
            if !Parser.parse(source: reordered).hasError {
                // Only identical declarations may depend on order (their keys carry a number)
                let unnumbered = original.filter { !$0.key.contains("#") }
                let after = identities(reordered)
                for (key, identity) in unnumbered where after[key] != nil { #expect(after[key] == identity, "members swapped: \(key) names another mutant in \(path)") }
            }
        }
    }
}

/// The member blocks of a file: where their contents start, and the ranges of their first two members.
private final class MemberBlockFinder: SyntaxVisitor {
    struct Body {
        var afterBrace: Int
        var firstTwoMembers: (first: (start: Int, end: Int), second: (start: Int, end: Int))?
    }

    var bodies: [Body] = []

    static func find(in tree: SourceFileSyntax) -> [Body] {
        let finder = MemberBlockFinder(viewMode: .sourceAccurate)
        finder.walk(tree)
        return finder.bodies
    }

    override func visit(_ node: MemberBlockSyntax) -> SyntaxVisitorContinueKind {
        // Enum cases and protocol requirements are left alone
        guard node.parent?.is(ProtocolDeclSyntax.self) != true else { return .skipChildren }
        var body = Body(afterBrace: node.leftBrace.endPositionBeforeTrailingTrivia.utf8Offset)
        let functions = node.members.filter { $0.decl.is(FunctionDeclSyntax.self) }
        if functions.count >= 2, node.members.allSatisfy({ !$0.decl.is(IfConfigDeclSyntax.self) }) {
            let list = Array(functions.prefix(2))
            func range(_ item: MemberBlockItemSyntax) -> (start: Int, end: Int) {
                (item.positionAfterSkippingLeadingTrivia.utf8Offset, item.endPositionBeforeTrailingTrivia.utf8Offset)
            }
            body.firstTwoMembers = (range(list[0]), range(list[1]))
        }
        // Swapping in nested blocks at the same time would overlap ranges: only the outermost blocks are swapped
        if bodies.contains(where: { $0.firstTwoMembers != nil }), node.ancestors.contains(where: { $0.is(MemberBlockSyntax.self) }) {
            body.firstTwoMembers = nil
        }
        bodies.append(body)
        return .visitChildren
    }
}

private extension SyntaxProtocol {
    var ancestors: [Syntax] {
        var result: [Syntax] = []
        var current = parent
        while let node = current {
            result.append(node)
            current = node.parent
        }
        return result
    }
}

/// Functions with at least one parameter, and an overload of each that differs in the type of the first parameter.
private final class FunctionFinder: SyntaxVisitor {
    var functions: [(start: Int, overload: String)] = []

    static func find(in tree: SourceFileSyntax) -> [(start: Int, overload: String)] {
        let finder = FunctionFinder(viewMode: .sourceAccurate)
        finder.walk(tree)
        return finder.functions
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        // Only functions that are members or at the top level: a function added inside another function is a statement
        // added before the statements that follow, which changes their keys (as documented)
        guard let first = node.signature.parameterClause.parameters.first, node.body != nil,
              node.parent?.is(MemberBlockItemSyntax.self) == true || node.parent?.parent?.parent?.is(SourceFileSyntax.self) == true,
              !node.ancestors.contains(where: { $0.is(FunctionDeclSyntax.self) || $0.is(ClosureExprSyntax.self) || $0.is(AccessorDeclSyntax.self) || $0.is(InitializerDeclSyntax.self) }),
              node.attributes.isEmpty else { return .visitChildren }
        // `func name(label x: __Other, …rest) { fatalError() }`, on the line before the function
        let modifiers = node.modifiers.filter { ["static", "class", "public", "private", "fileprivate", "internal", "mutating", "nonisolated"].contains($0.name.text) }
            .map(\.name.text).joined(separator: " ")
        let rest = node.signature.parameterClause.parameters.dropFirst().map(\.trimmedDescription).joined(separator: " ")
        let firstText = "\(first.firstName.text)\(first.secondName.map { " " + $0.text } ?? ""): __Other\(node.signature.parameterClause.parameters.count > 1 ? "," : "")"
        let overload = "\(modifiers) func \(node.name.text)(\(firstText) \(rest)) { fatalError() } ; "
        functions.append((node.positionAfterSkippingLeadingTrivia.utf8Offset, overload))
        return .visitChildren
    }
}
