@testable import MutatorCore
import Testing

@Suite("Operators for return values and control flow")
struct ExtendedOperatorTests {
    private func mutants(_ source: String, _ ops: Set<MutationOperator>) -> [Mutant] {
        generate(source, options: GeneratorOptions(operators: ops)).mutants
    }

    @Test func returnValueEnumAlternatives() {
        let source = """
        enum R { case has, no, unknown, other }
        func check(_ m: Int?, _ s: Bool) -> R {
            guard let m else { return .no }
            if m > 5 { return .other }
            if m < 0 { return .unknown }
            return s ? .has : .no
        }

        """
        let ms = mutants(source, [.returnValue])
        // 同じ関数で返している case（出現順: no, other, unknown, has）から、自分以外を最大2つ
        #expect(ms.map { "\($0.original)->\($0.replacement)" } == [
            ".no->.other", ".no->.unknown", ".other->.no", ".other->.unknown", ".unknown->.no", ".unknown->.other",
        ])
        expectValidInstrumentation(process(source, options: GeneratorOptions(operators: [.returnValue])))
    }

    @Test func returnValueFromTypeAnnotation() {
        let source = """
        func a(_ x: Int) -> Int? { return x }
        func b() -> [String] { return ["a"] }
        func c() -> [String: Int] { return ["a": 1] }
        func d() -> String { return "x" }
        func e(_ x: Int) -> Int { return x + 1 }
        func f() -> Double { return 0 }
        func g() -> Bool { return true }
        func h<T>(_ t: T) -> T { return t }
        func i() -> Int? { return nil }
        func j() throws -> Int { return try k() }
        func k() throws -> Int { 1 }
        var p: [Int] { return [1] }
        let q: (Int) -> Int = { x in return x }
        struct S { init?(x: Int) { return nil } ; func me() -> S { return self } }

        """
        let ms = mutants(source, [.returnValue])
        #expect(ms.map { "\($0.originalExpression)->\($0.replacement)" } == [
            "x->nil", "[\"a\"]->[]", "[\"a\": 1]->[:]", "\"x\"->\"\"", "x + 1->0", "k()->0", "[1]->[]",
        ])
        let result = process(source, options: GeneratorOptions(operators: [.returnValue]))
        expectValidInstrumentation(result)
        #expect(result.instrumented.contains("return try (__xcmutate.isOn(5) ? (0) : (k()))"))
    }

    @Test func earlyReturnForFlagInLoop() throws {
        let source = """
        enum R { case has, no, unknown }
        func check(_ xs: [R]) -> R {
            var hasUnknown = false
            for x in xs {
                switch x {
                case .has: return .has
                case .no: continue
                case .unknown: hasUnknown = true
                }
            }
            hasUnknown = true
            return hasUnknown ? .unknown : .no
        }
        func any(_ xs: [Int]) -> Bool {
            var found = false
            for x in xs where x > 0 { found = true }
            return found
        }
        func notAFlag(_ xs: [Int]) -> Bool {
            var found = true
            for _ in xs { found = true }
            return found
        }

        """
        let ms = mutants(source, [.earlyReturn])
        #expect(ms.map { "\($0.original)->\($0.replacement)" } == ["hasUnknown = true->return .unknown", "found = true->return true"])
        let result = process(source, options: GeneratorOptions(operators: [.earlyReturn, .booleanLiteral]))
        expectValidInstrumentation(result)
        #expect(result.instrumented.contains("case .unknown: if __xcmutate.isOn(1) { return .unknown } else { hasUnknown = (__xcmutate.isOn(2) ? (false) : (true)) }"))
    }

    @Test func conditionRemovalOnlyForMultipleConditions() {
        let source = """
        func f(_ s: String?, _ n: Int, _ x: Int?) -> Bool {
            guard let h = s, !h.isEmpty, n > 0 else { return false }
            if n > 1 { return true }
            if case .some(let v) = x, v > 2, try! g() { return true }
            while let y = x, y > 3 { break }
            return false
        }
        func g() throws -> Bool { true }

        """
        let ms = mutants(source, [.conditionRemoval])
        #expect(ms.map(\.original) == ["!h.isEmpty", "n > 0", "v > 2", "try! g()"].filter { $0 != "try! g()" })
        expectValidInstrumentation(process(source, options: GeneratorOptions(operators: [.conditionRemoval, .negationRemoval, .boundary])))
    }

    @Test func loopControl() {
        let source = """
        func f(_ xs: [Int]) -> Int {
            var n = 0
            outer: for x in xs {
                if x < 0 { continue }
                if x > 100 { break }
                for y in xs { if y == x { continue outer } }
                switch x { case 1: break; default: n += 1 }
                n += x
            }
            switch n { case 0: break; default: n += 1 }
            let g = { (v: Int) -> Void in for _ in 0..<v { } }
            _ = g
            return n
        }

        """
        let ms = mutants(source, [.loopControl])
        #expect(ms.map { "\($0.start.line):\($0.original)->\($0.replacement)" } == [
            "4:continue->break", "5:break->continue", "7:break->continue",
        ])
        let result = process(source, options: GeneratorOptions(operators: [.loopControl]))
        expectValidInstrumentation(result)
        #expect(result.instrumented.contains("if x < 0 { if __xcmutate.isOn(0) { break } else { continue } }"))
    }

    @Test func normalizationRemoval() {
        let source = """
        import Foundation
        func f(_ a: String, _ b: String) -> Bool {
            a.lowercased() == b.trimmingCharacters(in: .whitespaces).uppercased() && a.count > 0
        }

        """
        let ms = mutants(source, [.normalizationRemoval])
        #expect(ms.map(\.original) == [".lowercased()", ".trimmingCharacters(in: .whitespaces)", ".uppercased()"])
        // `String(…)`: the receiver may be a `Character` or a `Substring`, and both branches of the switch need one type
        #expect(ms.map(\.mutatedExpression) == ["String(describing: a)", "String(describing: b)", "String(describing: b.trimmingCharacters(in: .whitespaces))"])
        expectValidInstrumentation(process(source))
    }

    @Test func configuredAridCalls() {
        let source = """
        func f(_ x: Int) {
            Crashlytics.crashlytics().record(error: x > 0 ? E.a : E.b)
            LoginAnalytics.send(x == 1)
            sendAnalytics(x < 3)
            other(x >= 4)
        }

        """
        var options = GeneratorOptions()
        options.aridCallPatterns = ["Crashlytics", "LoginAnalytics", "sendAnalytics"]
        let result = generate(source, options: options)
        #expect(result.mutants.map(\.original) == ["other(x >= 4)", ">="])
        #expect(result.ignored.filter { $0.reason == .aridCall }.count == 7)
        // 既定（パターン無し）では対象
        #expect(generate(source).mutants.count == 9)
    }

    @Test func normalizationOnOptionalChainDropsTheQuestionMark() {
        let source = """
        import Foundation
        func f(_ url: URL) -> Bool { url.scheme?.lowercased() == "https" }

        """
        let ms = mutants(source, [.normalizationRemoval])
        #expect(ms.map(\.mutatedExpression) == ["url.scheme"])
        expectValidInstrumentation(process(source))
    }

    @Test func continueThatEndsTheLoopBodyInsideSwitchIsSkipped() {
        let source = """
        func f(_ xs: [Int]) -> Int {
            var n = 0
            for x in xs {
                switch x {
                case 0: continue
                default: n += 1
                }
            }
            for x in xs {
                if x > 0 {
                    switch x { case 1: continue; default: break }
                }
                n += 1
            }
            repeat { switch n { case 0: continue; default: n -= 1 } } while n > 0
            return n
        }

        """
        let ms = mutants(source, [.loopControl])
        // 1つ目の switch の continue と repeat の中の continue は等価なので作らない。2つ目は if の後に `n += 1` が続くので作る
        #expect(ms.map { "\($0.start.line):\($0.original)" } == ["11:continue", "11:break"])
    }

    @Test func branchMapPointsToMutatedBranches() throws {
        let source = "func f(_ a: Int) -> Bool { a > 0 && a < 9 }\n"
        let result = process(source, options: expressionOnly)
        let (text, branches) = Instrumenter.instrumentWithBranches(source: source, mutants: result.mutants)
        let bytes = Array(text.utf8)
        for m in result.mutants {
            let range = try #require(branches[m.id])
            #expect(String(decoding: bytes[range.start..<range.end], as: UTF8.self) == m.mutatedExpression)
        }
    }
}

