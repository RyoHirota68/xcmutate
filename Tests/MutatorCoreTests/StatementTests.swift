@testable import MutatorCore
import Testing

@Suite("副作用の文の削除")
struct StatementTests {
    private func statements(_ source: String) -> (mutants: [Mutant], ignored: [IgnoredMutant]) {
        let result = generate(source, options: GeneratorOptions(operators: [.sideEffectRemoval]))
        return (result.mutants, result.ignored)
    }

    @Test func discardedCallsAreCandidates() {
        let r = statements("""
        final class Repo { @discardableResult func save(_ x: Int) -> Int { x } ; func store(_ x: Int) {} }
        func f(_ repo: Repo) async throws {
            repo.store(1)
            _ = repo.save(2)
            repo.save(3)
            try g()
            await h()
            try await k()
            let x = repo.save(4)
            _ = x
        }
        func g() throws {}
        func h() async {}
        func k() async throws {}

        """)
        #expect(r.mutants.map(\.original) == ["repo.store(1)", "_ = repo.save(2)", "repo.save(3)", "try g()", "await h()", "try await k()"])
        #expect(r.mutants.allSatisfy { $0.operator == .sideEffectRemoval && $0.mutatedExpression.isEmpty && $0.replacement.isEmpty })
        #expect(r.ignored.isEmpty)
    }

    @Test func embeddingWrapsStatementInIf() {
        let source = "func f(_ items: inout [Int], _ n: Int) {\n    items.append(n > 0 ? n : 0)\n}\n"
        let result = process(source)
        expectValidInstrumentation(result)
        let lines = result.instrumented.split(separator: "\n")
        #expect(lines[1] == "    if !__xcmutate.isOn(0) { items.append((__xcmutate.isOn(1) ? (n >= 0) : __xcmutate.isOn(2) ? (!(n > 0)) : (n > 0)) ? n : 0) }")
    }

    @Test func multiLineStatementKeepsLineNumbers() {
        let source = """
        func f(_ items: inout [Int]) {
            items.append(contentsOf: [
                1, // one
                2,
            ])
        }

        """
        let result = process(source)
        expectValidInstrumentation(result)
        #expect(result.mutants.count == 1)
        #expect(!result.verification.lineCountChanged)
    }

    @Test func closureBodiesAndTopLevelAreNotCandidates() {
        let r = statements("""
        import Foundation
        print("top")
        func f(_ xs: [Int]) {
            xs.forEach { x in print(x); store(x) }
            DispatchQueue.main.async { store(1) }
        }
        func store(_ x: Int) {}

        """)
        // forEach と async の呼び出し自体は関数本体の文なので候補。クロージャの中の文は候補にしない。
        #expect(r.mutants.map(\.original).map { String($0.prefix(14)) } == ["xs.forEach { x", "DispatchQueue."])
        #expect(r.ignored.isEmpty)
    }

    @Test func exclusionReasons() {
        let r = statements("""
        import UIKit
        import os
        final class Lockable { let lock = NSLock(); let sem = DispatchSemaphore(value: 1) }
        class Base { init(id: Int) {} }
        final class Sub: Base {
            init() { super.init(id: 1) }
            convenience init(flag: Bool) { self.init() }
            deinit { cleanup() }
            func cleanup() {}
        }
        func failHard() -> Never { fatalError("x") }
        func total() -> Int { compute() }
        func compute() -> Int { 1 }
        var computed: Int { compute() }
        func f(_ v: UIView, _ l: Lockable, _ ok: Bool, logger: Logger) {
            print("x")
            logger.info("y")
            v.setNeedsLayout()
            v.layoutIfNeeded()
            l.lock.lock()
            l.lock.unlock()
            l.sem.signal()
            if !ok { failHard() }
            preconditionFailure("z")
            guard ok else { v.removeFromSuperview(); compute2() }
        }
        func compute2() -> Never { abort() }
        @inlinable public func inl(_ v: UIView) { v.removeFromSuperview() }
        // xcmutate:disable-next-line
        func disabled(_ v: UIView) { v.removeFromSuperview() }

        """)
        let reasons = r.ignored.map { "\($0.start.line):\($0.reason.rawValue)" }
        #expect(reasons == [
            "6:initializer-delegation", "7:initializer-delegation", "8:deinit", "11:never-returning",
            "12:implicit-return", "14:implicit-return", "16:arid-call", "17:arid-call", "18:arid-call", "19:arid-call",
            "20:synchronization", "21:synchronization", "22:synchronization", "23:never-returning", "24:never-returning",
            "25:never-returning", "27:never-returning", "28:inlinable-body", "30:disabled-by-comment",
        ])
        // guard の else 節の最後ではない文は候補。
        #expect(r.mutants.map(\.original) == ["v.removeFromSuperview()"])
    }

    @Test func guardElseLastStatementIsExcluded() {
        let r = statements("""
        func f(_ ok: Bool) {
            guard ok else { log(); bail() }
        }
        func log() {}
        func bail() {}

        """)
        #expect(r.mutants.map(\.original) == ["log()"])
        #expect(r.ignored.map(\.reason) == [.guardElse])
    }

    @Test func resultBuilderBodies() {
        let r = statements("""
        import SwiftUI
        struct V: View {
            var body: some View { makeText() }
            func makeText() -> Text { Text("a") }
            @ViewBuilder func content() -> some View { makeText(); makeText() }
        }

        """)
        #expect(r.mutants.isEmpty)
        #expect(r.ignored.map(\.reason) == [.resultBuilder, .implicitReturn, .resultBuilder, .resultBuilder])
    }

    @Test func voidSingleStatementBodyIsACandidate() {
        let r = statements("final class C { var v = 0; func set() { update() }; func update() { v += 1 } }\n")
        #expect(r.mutants.map(\.original) == ["update()"])
    }

    @Test func scopeAndRegionLines() throws {
        let source = """
        struct S {
            func f(_ a: Int) -> Bool {
                let x = a > 0 &&
                    a < 10
                return x
            }
        }

        """
        let result = generate(source)
        let and = try #require(result.mutants.first { $0.original == "&&" })
        #expect(and.regionLines == LineSpan(start: 3, end: 4))
        #expect(and.scope.lines == LineSpan(start: 2, end: 6))
        // The scope is the function; a local `let` is not a declaration of its own (reports group by scope)
        #expect(and.scope.id == "S.f(_:)")
        #expect(and.enclosingDecl == "S.f(_:)")
        // A stored property and a global are
        let members = generate("struct T {\n    var limit = 1 > 0\n}\nlet top = 2 > 1\n").mutants.map(\.enclosingDecl)
        #expect(Set(members) == ["T.limit", "top"])
    }
}
