import Foundation
@testable import MutatorCore
@testable import MutatorRunner
import Testing

@Suite("Regressions of early defects, and the operators added with them")
struct DefectRegressionTests {
    // MARK: 判定（純粋関数）

    static func summary(failed: Int, total: Int = 3, message: String = "XCTAssertEqual failed") -> TestSummary {
        TestSummary(result: failed > 0 ? "Failed" : "Passed", totalTestCount: total, passedTests: total - failed,
                    failedTests: failed, skippedTests: 0, expectedFailures: 0,
                    failures: (0..<failed).map { .init(test: "T/test\($0)()", message: message) })
    }

    @Test(arguments: [
        // (終了コード, タイムアウト, 要約, 有効化, 期待)
        (Int32(0), false, summary(failed: 0), true, MutantStatus.survived),
        (0, false, summary(failed: 0), false, .notActivated),
        (65, false, summary(failed: 1), true, .killed),
        (65, false, summary(failed: 1, message: "Crash: SampleApp at f()"), true, .crash),
        (65, false, summary(failed: 1), false, .runnerError),
        (15, true, nil, true, .timeout),
        (15, true, nil, false, .runnerError),       // 有効化される前のタイムアウトは検出に数えない
        (65, false, nil, true, .runnerError),        // xcresult が無い
        (0, false, summary(failed: 0, total: 0), true, .runnerError),  // テストが1件も動かない
        (70, false, nil, false, .runnerError),
    ] as [(Int32, Bool, TestSummary?, Bool, MutantStatus)])
    func classify(exit: Int32, timedOut: Bool, summary: TestSummary?, activated: Bool, expected: MutantStatus) {
        let result = Judgement.classify(exitStatus: exit, timedOut: timedOut, summary: summary, activated: activated,
                                        timeout: 60, logText: "")
        #expect(result.status == expected)
        if expected == .killed || expected == .crash { #expect(result.killedBy == ["T/test0()"]) }
    }

    // MARK: Optional チェーン

    @Test func normalizationInsideOptionalChainKeepsTheChain() throws {
        let source = """
        struct User { var name: String }
        func a(_ u: User?) -> Bool? { u?.name.lowercased().hasPrefix("a") }
        func b(_ u: User?) -> Int? { u?.name.uppercased().hashValue }
        func c(_ s: String?) -> Bool { s?.lowercased() == "x" }

        """
        let result = process(source, options: GeneratorOptions(operators: [.normalizationRemoval]))
        expectValidInstrumentation(result)
        #expect(result.mutants.map(\.mutatedExpression) == ["u?.name.hasPrefix(\"a\")", "u?.name.hashValue", "s"])
        #expect(result.instrumented.contains("(__xcmutate.isOn(0) ? (u?.name.hasPrefix(\"a\")) : (u?.name.lowercased().hasPrefix(\"a\")))"))
    }

    @Test func regionInsideOptionalChainIsExcluded() {
        // 範囲を括弧で包むとチェーンが切れる候補は作らない（今の演算子では normalization 以外に起きないことの確認も兼ねる）
        let source = "func f(_ u: [String]?) -> Int? { u?.first?.lowercased().count }\n"
        let ms = generate(source, options: GeneratorOptions()).mutants
        #expect(ms.allSatisfy { !$0.originalExpression.hasSuffix(".lowercased()") || $0.operator != .normalizationRemoval })
        let r = process(source, options: GeneratorOptions())
        expectValidInstrumentation(r)
    }

    // MARK: 文の削除と同じ範囲

    @Test func statementAndExpressionWithTheSameRangeDoNotCrash() {
        let source = "func f(_ s: String) {\n    s.lowercased()\n}\n"
        let result = process(source, options: GeneratorOptions())
        expectValidInstrumentation(result)
        #expect(result.mutants.map(\.operator) == [.sideEffectRemoval])
        #expect(generate(source, options: GeneratorOptions()).ignored.map(\.reason) == [.sameRangeAsStatement])
    }

    // MARK: 差分と上限

    @Test func diffIsAppliedBeforeTheLimit() throws {
        let source = """
        func ok(_ a: Int, _ b: Int, _ c: Int, _ d: Int) -> Bool {
            return a > 0
                && b > 0
                && c > 0
                && d > 0
                && a < 100
                && b < 100
                && c < 100
                && d < 200
        }

        """
        let options = GeneratorOptions(maxSwitchesPerExpression: 8, operators: [.boundary, .logicalConnector])
        let changed = FileProcessor(options: options).process(source: source, file: "F.swift", firstID: 0, changedLines: [9...9])
        #expect(Set(changed.mutants.map(\.original)) == ["&&", "<"])
        // 差分が無いときも、比較と && → || の両方が残る（種類が偏らない）
        let all = generate(source, options: options)
        let kept = Dictionary(grouping: all.mutants, by: \.operator).mapValues(\.count)
        #expect(kept[.boundary] == 4)
        #expect(kept[.logicalConnector] == 4)
    }

    // MARK: break → continue の等価な形

    @Test func equivalentBreakInSwitchIsSkipped() {
        let source = """
        enum K { case a, b }
        func f(_ xs: [K]) -> Int {
            var n = 0
            for x in xs {
                switch x {
                case .a: break
                case .b: n += 1
                }
            }
            for x in xs {
                switch x { case .a: break; case .b: n += 2 }
                n += 1
            }
            return n
        }

        """
        let ms = generate(source, options: GeneratorOptions(operators: [.loopControl])).mutants
        #expect(ms.map(\.start.line) == [11])
    }

    // MARK: コンパイルできない候補

    @Test func compileErrorCandidatesAreNotCreated() {
        let source = """
        @available(macOS 13, *)
        public struct L { @backDeployed(before: macOS 14) public func over(_ a: Int) -> Bool { a > 10 } }
        func kind(_ n: Int) -> String {
            return switch n { case 0: "zero"; default: "pos" }
        }
        @discardableResult func compute() -> Int { 1 }
        func g(_ c: Bool) -> Int {
            let x = if c { compute() } else { 0 }
            return x
        }

        """
        let r = generate(source, options: GeneratorOptions())
        #expect(!r.mutants.contains { $0.operator == .returnValue && $0.originalExpression.hasPrefix("switch") })
        #expect(!r.mutants.contains { $0.operator == .sideEffectRemoval && $0.original == "compute()" })
        #expect(r.ignored.contains { $0.reason == .inlinableBody })
    }

    // MARK: 新しい演算子

    @Test func newOperators() {
        let source = """
        final class VM {
            var items: [Int] = []
            var isAdmin: Bool { items.contains(1) }
            func canEdit(_ id: Int) -> Bool {
                guard isAdmin else { return false }
                if items.isEmpty, id > 0 { return false }
                return items.contains(id)
            }
            func total() -> Int { items.count * 2 + 1 }
            func both(_ a: Bool, _ b: Bool) -> Bool { a && b || false }
            func clamp(_ x: Int) -> Int { min(max(x, 0), 10) }
            func name(_ s: String?) -> String { s ?? "none" }
            func n(_ s: Int?) -> Int { s ?? 0 }
            func label(_ s: String?) -> String { "x" + (s ?? "") }
        }

        """
        let ops: Set<MutationOperator> = [.conditionNegation, .returnNegation, .operandRemoval, .arithmetic, .nilCoalescingDefault, .minMax]
        let ms = generate(source, options: GeneratorOptions(operators: ops)).mutants
        let byOp = Dictionary(grouping: ms, by: \.operator).mapValues { $0.map(\.mutatedExpression) }
        #expect(byOp[.conditionNegation] == ["!(isAdmin)", "!(items.isEmpty)"])
        #expect(byOp[.returnNegation] == ["!(items.contains(1))", "!(items.contains(id))"])
        // `(a && b) || false` の左（`a && b` → false）と、`a && b` の a・b（→ true）。リテラルの `false` は外さない
        #expect(byOp[.operandRemoval]?.sorted() == ["false", "true", "true"])
        #expect(byOp[.arithmetic]?.count == 2)  // `*` と `+`。文字列の `+` は作らない
        #expect(byOp[.nilCoalescingDefault] == ["\"\"", "1", "\"mutated\""])
        #expect(byOp[.minMax] == ["max(max(x, 0), 10)", "min(x, 0)"])
        let result = process(source, options: GeneratorOptions(operators: ops))
        expectValidInstrumentation(result)
    }
}
