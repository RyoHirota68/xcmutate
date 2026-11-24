@testable import MutatorCore
import Testing

let expressionOnly = GeneratorOptions(operators: [.equalityFlip, .boundary, .logicalConnector, .negationRemoval, .booleanLiteral, .ternarySwap])

@Suite("埋め込まない位置")
struct ExclusionTests {
    /// 式の単位の演算子だけで生成する（文の削除は StatementTests で確かめる）。
    private func reasons(_ source: String) -> (mutants: [Mutant], reasons: [IgnoreReason]) {
        let result = generate(source, options: expressionOnly)
        return (result.mutants, ignoredReasons(result))
    }

    @Test func ifConfigCondition() {
        let r = reasons("""
        #if DEBUG && os(iOS)
        let a = 1 > 0
        #elseif !targetEnvironment(simulator)
        #endif

        """)
        #expect(r.reasons == [.ifConfigCondition, .ifConfigCondition])
        // 分岐の中（有効か無効かは問わない）の比較は対象にする。
        #expect(r.mutants.map(\.original) == [">"])
    }

    @Test func macroExpansionArguments() {
        let r = reasons("""
        import Foundation
        let p = #Predicate<Int> { $0 > 18 }
        func f(_ a: Int) { #expect(a == 1) }
        #Preview { Text(1 > 0 ? "a" : "b") }

        """)
        #expect(r.mutants.isEmpty)
        #expect(Set(r.reasons) == [.macroExpansion])
        #expect(r.reasons.count == 4)
    }

    @Test func attributeArguments() {
        let r = reasons("""
        struct S {
            @Clamped(max: 10 > 3) var v = 1
            @Test(.enabled(if: true)) func t() {}
            @available(iOS 17, *) func g() {}
        }

        """)
        #expect(r.mutants.isEmpty)
        #expect(r.reasons == [.attributeArgument, .attributeArgument])
    }

    @Test func whereClausesOfTypes() {
        let r = reasons("""
        struct Box<T> { var v: T }
        extension Box: Equatable where T == String {}
        func f<T>(_ t: T) where T: Equatable {}

        """)
        // 型の制約の `==` は式ではないので候補にもならない。
        #expect(r.mutants.isEmpty)
        #expect(r.reasons.isEmpty)
    }

    @Test func forAndCaseWhereClausesAreMutated() {
        let r = reasons("""
        func f(_ xs: [Int]) -> Int {
            for x in xs where x > 0 { return x }
            switch xs.count { case let v where v > 1: return v; default: return 0 }
        }

        """)
        #expect(r.mutants.count == 2)
        #expect(r.reasons.isEmpty)
    }

    @Test func enumRawValuesAndAssociatedDefaults() {
        let r = reasons("""
        enum Level: Int { case low = 1, high = 2 }
        enum Flag: String { case on = "on" }
        enum E { case a(x: Bool = true) }

        """)
        #expect(r.mutants.isEmpty)
        #expect(r.reasons == [.enumCase])
    }

    @Test func patterns() {
        let r = reasons("""
        func f(_ b: Bool, _ x: Int?) -> Int {
            switch b { case true: return 1; case false: return 0 }
        }
        func g(_ x: Int?) -> Bool { if case .some(let v) = x, v > 0 { return true }; return false }

        """)
        #expect(r.reasons == [.pattern, .pattern])
        #expect(r.mutants.map(\.original) == [">", "true", "false"])
    }

    @Test func keyPathsAndInout() {
        let r = reasons("""
        struct S { var a: [Bool] = [] }
        func f(_ s: inout S) {
            let k = \\S.a[0 > 1 ? 0 : 1]
            swap(&s.a[0], &s.a[1])
            _ = k
        }

        """)
        #expect(Set(r.reasons) == [.keyPath])
        #expect(r.mutants.isEmpty)
    }

    @Test func deinitAndOperatorDeclarations() {
        let r = reasons("""
        final class C { var n = 0; deinit { if n > 0 { n = 0 } } }
        precedencegroup Pow {
            higherThan: MultiplicationPrecedence
            associativity: right
            assignment: false
        }
        infix operator ** : Pow
        struct Version: Comparable {
            var major: Int
            static func < (l: Version, r: Version) -> Bool { l.major < r.major }
        }

        """)
        #expect(r.reasons == [.deinitializer])
        // 演算子の実装の本体は対象、宣言は対象外（候補にもならない）。
        #expect(r.mutants.map(\.original) == ["<"])
    }

    @Test func inlinableBodies() {
        let r = reasons("""
        @inlinable public func a(_ x: Int) -> Bool { x > 0 }
        @_alwaysEmitIntoClient public func b(_ x: Int) -> Bool { x > 0 }
        @_transparent public func c(_ x: Int) -> Bool { x > 0 }
        public struct S { @inlinable public var p: Bool { 1 > 0 } }
        public func d(_ x: Int) -> Bool { x > 0 }

        """)
        #expect(r.reasons == Array(repeating: .inlinableBody, count: 4))
        #expect(r.mutants.count == 1)
    }

    @Test func defaultArguments() {
        let r = reasons("""
        let retries = 5
        func internalFetch(force: Bool = retries > 3) {}
        public func publicFetch(force: Bool = retries > 3) {}
        public extension Array { func g(flag: Bool = false) {} }
        public struct T { public init(x: Bool = true) {} }
        @frozen public struct F { var v = retries > 1 }

        """)
        #expect(r.mutants.map(\.enclosingDecl) == ["internalFetch(force:)"])
        #expect(r.reasons == [.publicDefaultArgument, .publicDefaultArgument, .publicDefaultArgument, .frozenPropertyInitializer])
    }

    @Test func aridCalls() {
        let r = reasons("""
        import os
        let logger = Logger()
        func f(_ a: Int, _ b: Int) {
            print(a > b)
            debugPrint(a == b)
            assert(a > 0, "positive")
            precondition(b >= 0)
            logger.info("\\(a > b)")
            Self.log.debug("\\(a < b)")
            os_log("%d", a > b ? 1 : 0)
            fatalError(a > b ? "x" : "y")
            let ok = a > b
            _ = ok
        }

        """)
        #expect(Set(r.reasons) == [.aridCall])
        #expect(r.reasons.count == 10)
        #expect(r.mutants.count == 1)
    }

    @Test func aridArgumentAndConstantConditions() {
        let r = reasons("""
        func f(_ v: UIView, _ ok: Bool) -> Int {
            v.set(hidden: true, animated: true)
            while true { if ok { break } }
            repeat { } while false
            if true { return 1 }
            return ok ? 1 : 0
        }

        """)
        #expect(r.reasons == [.aridArgument, .constantCondition, .constantCondition, .constantCondition])
        #expect(r.mutants.map(\.operator) == [.booleanLiteral, .ternarySwap])
    }

    @Test func unfoldableCustomOperator() {
        // 優先順位の分からない独自演算子（他のファイルで宣言）を含む列は、まとめて対象外にする。
        let r = reasons("func f(_ a: Int, _ b: Int) -> Bool { a <~> b > 0 && true }\n")
        #expect(r.mutants.isEmpty)
        #expect(Set(r.reasons) == [.unfoldableOperators])
        // 同じファイルで優先順位グループを宣言していれば畳み込める。
        let declared = reasons("""
        precedencegroup Spaceship { higherThan: ComparisonPrecedence }
        infix operator <~> : Spaceship
        func <~> (l: Int, r: Int) -> Int { l - r }
        func f(_ a: Int, _ b: Int) -> Bool { a <~> b > 0 && true }

        """)
        #expect(declared.reasons.isEmpty)
        #expect(declared.mutants.map(\.original) == [">", "&&", "true"])
    }

    @Test func disableComments() {
        let r = reasons("""
        func f(_ a: Int) -> Bool {
            let x = a > 0 // xcmutate:disable-line
            // xcmutate:disable-next-line
            let y = a > 1
            // xcmutate:disable
            let z = a > 2
            let w = a > 3
            // xcmutate:enable
            return x && y && z && w && a > 4
        }

        """)
        #expect(r.reasons == Array(repeating: .disabledByComment, count: 4))
        #expect(r.mutants.map(\.original) == ["&&", "&&", "&&", "&&", ">"])
    }

    @Test func tooManySwitchesInOneExpression() {
        var options = expressionOnly
        options.maxSwitchesPerExpression = 3
        let result = generate("func f(_ a: Int) -> Bool { a > 0 && a < 9 && a != 5 }\n", options: options)
        #expect(result.mutants.count == 3)
        #expect(ignoredReasons(result) == [.tooManyInExpression, .tooManyInExpression])
        let separate = generate("func f(_ a: Int) -> (Bool, Bool) { (a > 0 && a < 9, a != 5 && a > 1) }\n", options: options)
        #expect(separate.mutants.count == 6)
    }

    @Test func fileWithParseErrorIsSkipped() {
        let result = generate("func f( { a > b\n")
        #expect(result.mutants.isEmpty)
        #expect(result.skippedReason == "parse-error")
        let processed = process("func f( { a > b\n")
        #expect(processed.instrumented == "func f( { a > b\n")
        #expect(processed.verification.isValid)
    }
}
