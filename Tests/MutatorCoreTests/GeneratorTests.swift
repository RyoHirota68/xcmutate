@testable import MutatorCore
import SwiftParser
import Testing

@Suite("演算子ごとの生成")
struct OperatorTests {
    @Test(arguments: [
        ("==", "!=", MutationOperator.equalityFlip),
        ("!=", "==", .equalityFlip),
        ("<", "<=", .boundary),
        ("<=", "<", .boundary),
        (">", ">=", .boundary),
        (">=", ">", .boundary),
    ])
    func comparison(op: String, replacement: String, kind: MutationOperator) throws {
        let source = "func f(_ a: Int, _ b: Int) -> Bool { a \(op) b }\n"
        let result = generate(source)
        #expect(result.ignored.isEmpty)
        let mutant = try #require(result.mutants.only)
        #expect(mutant.operator == kind)
        #expect(mutant.original == op)
        #expect(mutant.replacement == replacement)
        #expect(mutant.originalExpression == "a \(op) b")
        #expect(mutant.mutatedExpression == "a \(replacement) b")
        #expect(pointText(source, mutant.point) == op)
    }

    @Test func logicalConnectors() {
        let result = generate("func f(_ a: Bool, _ b: Bool) -> Bool { (a && b) || a }\n")
        #expect(result.mutants.map(\.mutatedExpression) == ["a || b", "(a && b) && a"])
        #expect(result.mutants.allSatisfy { $0.operator == .logicalConnector })
    }

    /// `&&` と `||` は優先順位が違うので、被演算子を括弧で囲んで木の形を保つ。
    @Test func logicalConnectorKeepsTreeShape() {
        let result = generate("func f(_ a: Bool, _ b: Bool, _ c: Bool) -> Bool { a || b || c }\n")
        #expect(result.mutants.map(\.mutatedExpression).sorted() == ["(a || b) && c", "a && b"])
        let andResult = generate("func f(_ x: Int, _ b: Bool) -> Bool { x > 0 && b }\n")
        #expect(andResult.mutants.contains { $0.mutatedExpression == "(x > 0) || b" })
    }

    @Test func negationRemoval() throws {
        let source = "func f(_ a: [Int]) -> Bool { !a.isEmpty }\n"
        let mutant = try #require(generate(source).mutants.only)
        #expect(mutant.operator == .negationRemoval)
        #expect(mutant.mutatedExpression == "a.isEmpty")
        #expect(pointText(source, mutant.point) == "!")
    }

    @Test func booleanLiterals() {
        let result = generate("let x = true\nlet y = false\n")
        #expect(result.mutants.map(\.mutatedExpression) == ["false", "true"])
        #expect(result.mutants.allSatisfy { $0.operator == .booleanLiteral })
    }

    @Test func ternarySwap() throws {
        let source = "func f(_ c: Bool) -> Int { c ? 1 : 2 }\n"
        let mutant = try #require(generate(source).mutants.only)
        #expect(mutant.operator == .ternarySwap)
        // The swap is embedded as the condition negated; the report shows it as the swap it is
        #expect(mutant.originalExpression == "c")
        #expect(mutant.mutatedExpression == "!(c)")
        #expect(mutant.original == "? 1 : 2")
        #expect(mutant.replacement == "? 2 : 1")
    }

    /// else 側が比較の三項（Muter #308 で壊れた形）と、三項の入れ子。
    @Test func ternaryWithComparisonAndNesting() {
        let result = process("""
        func f(_ r: Bool, _ a: Bool, _ b: Int, _ c: Int) -> Bool { return r ? a : b > c }
        func g(_ a: Bool, _ b: Bool) -> Int { a ? (b ? 1 : 2) : 3 }
        func h(_ a: Bool, _ b: Bool) -> Int { a ? 1 : b ? 2 : 3 }

        """)
        expectValidInstrumentation(result)
        let swaps = result.mutants.filter { $0.operator == .ternarySwap }
        #expect(swaps.map(\.replacement) == ["? b > c : a", "? 3 : (b ? 1 : 2)", "? 2 : 1", "? b ? 2 : 3 : 1", "? 3 : 2"])
        #expect(swaps.map(\.mutatedExpression) == ["!(r)", "!(a)", "!(b)", "!(a)", "!(b)"])
        let lines = result.instrumented.split(separator: "\n")
        #expect(lines[0] == "func f(_ r: Bool, _ a: Bool, _ b: Int, _ c: Int) -> Bool { return (__xcmutate.isOn(0) ? (!(r)) : (r)) ? a : (__xcmutate.isOn(1) ? (b >= c) : (b > c)) }")
        #expect(lines[2] == "func h(_ a: Bool, _ b: Bool) -> Int { (__xcmutate.isOn(4) ? (!(a)) : (a)) ? 1 : (__xcmutate.isOn(5) ? (!(b)) : (b)) ? 2 : 3 }")
    }

    /// 両分岐が同じテキストの三項は等価なので作らない。
    @Test func ternaryWithSameBranchesIsSkipped() {
        let result = generate("func f(_ c: Bool, _ x: Int) -> Int { c ? x : x }\n")
        #expect(result.mutants.isEmpty)
    }

    @Test func noSpacesAroundOperator() throws {
        let source = "func f(_ a: Int, _ b: Int) -> Bool { a>b }\n"
        let mutant = try #require(generate(source).mutants.only)
        #expect(mutant.mutatedExpression == "a>=b")
        let result = process(source)
        expectValidInstrumentation(result)
        #expect(result.instrumented.contains("(__xcmutate.isOn(0) ? (a>=b) : (a>b))"))
    }

    @Test func operatorSubsetOption() {
        let options = GeneratorOptions(operators: [.boundary])
        let result = generate("func f(_ a: Int) -> Bool { a > 0 && true }\n", options: options)
        #expect(result.mutants.map(\.operator) == [.boundary])
    }

    @Test func otherOperatorsAreNotMutated() {
        let result = generate("func f(_ a: Int, _ b: Int) -> Int { var x = a + b * 2 - a / b; x += 1; return x == 0 ? a : b }\n", options: expressionOnly)
        #expect(Set(result.mutants.map(\.operator)) == [.equalityFlip, .ternarySwap])
    }
}

@Suite("位置とID")
struct PositionTests {
    /// 比較の前に日本語のコメント・文字列・絵文字があっても、UTF-8 バイト位置がずれない（Muter #308）。
    @Test func multibyteCharactersBeforeMutant() throws {
        let source = """
        func f(_ a: Int, _ b: Int) -> Bool {
            // 日本語のコメント 🎉🇯🇵
            let s = "日本語の文字列 👨‍👩‍👧"; let t = /* ブロック 😀 */ a > b
            return s.isEmpty && t
        }

        """
        let result = process(source)
        expectValidInstrumentation(result)
        let gt = try #require(result.mutants.first { $0.original == ">" })
        #expect(pointText(source, gt.point) == ">")
        #expect(gt.start.line == 3)
        #expect(result.instrumented.contains("/* ブロック 😀 */ (__xcmutate.isOn(\(gt.id)) ? (a >= b) : (a > b))"))
    }

    /// 同じテキストの式が同じブロックに2回あっても、それぞれの位置に入る（Muter の range(of:) の問題）。
    @Test func sameExpressionTwice() throws {
        let source = """
        func f(_ a: Int, _ b: Int) -> (Bool, Bool) {
            let first = a > b
            let second = a > b
            return (first, second)
        }

        """
        let result = process(source)
        expectValidInstrumentation(result)
        #expect(result.mutants.count == 2)
        let lines = result.instrumented.split(separator: "\n")
        #expect(lines[1].contains("isOn(0)"))
        #expect(lines[2].contains("isOn(1)"))
        #expect(Set(result.mutants.map(\.key)).count == 2)
    }

    @Test func idsAreSequentialInSourceOrderAndOffsetByFirstID() {
        let result = process("func f(_ a: Int) -> Bool { a > 0 || a < -5 || !(a == 3) }\n", firstID: 100)
        expectValidInstrumentation(result)
        #expect(result.mutants.map(\.id) == Array(100..<(100 + result.mutants.count)))
        let starts = result.mutants.map(\.point.start)
        #expect(starts == starts.sorted())
    }

    /// 安定キーは、宣言より前に行を足しても変わらない。
    @Test func stableKeyDoesNotDependOnLineNumbers() {
        let body = "struct Cart { func total(_ a: Int) -> Bool { a > 0 && a < 10 } }\n"
        let before = generate(body).mutants.map(\.key)
        let after = generate("// header\n\nimport Foundation\n\n" + body).mutants.map(\.key)
        #expect(before == after)
        #expect(Set(before).count == before.count)
        #expect(before.allSatisfy { $0.hasPrefix("Test.swift::Cart.total(_:)::") })
    }

    @Test func enclosingDeclPath() {
        let result = generate("""
        struct Config { var isLarge = threshold > 10 }
        extension Config { init(x: Int) { self.isLarge = x > 1 } }
        let threshold = 3
        let top = threshold > 2

        """)
        #expect(result.mutants.map(\.enclosingDecl) == ["Config.isLarge", "extension Config.init(x:)", "top"])
    }

    @Test func lineAndColumn() throws {
        let source = "let a = 1\nlet b = 2\nlet c =   a <= b\n"
        let mutant = try #require(generate(source).mutants.only)
        #expect(mutant.start == SourcePosition(line: 3, column: 13))
        #expect(mutant.end == SourcePosition(line: 3, column: 15))
    }
}

@Suite("ネストした位置（Muter #322・#303）")
struct NestingTests {
    @Test func outerAndInnerClosure() {
        let source = """
        func f(_ x: Int, _ items: [Int], _ limit: Int) -> [Int] {
            if x > 0 {
                return items.filter { $0 > limit }
            }
            return items.sorted { $0 < $1 }.filter { v in v >= 0 }
        }

        """
        let result = process(source, options: expressionOnly)
        expectValidInstrumentation(result)
        #expect(result.mutants.count == 4)
        #expect(result.instrumented.contains("items.filter { (__xcmutate.isOn(1) ? ($0 >= limit) : ($0 > limit)) }"))
    }

    @Test func loopsAndOptionalBindings() {
        let source = """
        func f(_ values: [Int], _ total: Int, _ tol: Int, _ y: Int?) -> Int {
            var count = 0
            outer: for v in values where v > 0 {
                guard v >= 0 else { continue }
                for w in values {
                    if w > v { continue outer }
                }
                var i = 0
                while i < v { i += 1 }
                repeat { i -= 1 } while i > 0
                count += 1
            }
            if let last = values.last, last >= total - tol { count += 1 }
            guard let x = y, x > 3 else { return 0 }
            defer { if count > 0 { count = 0 } }
            values.forEach { if $0 == x { count += 1 } }
            switch x { case let v where v > 10: return v; default: break }
            let attempts: Int = { guard let d = y, d == 4 else { return 0 }; return d }()
            return count + attempts
        }

        """
        let result = process(source)
        expectValidInstrumentation(result)
        let originals = result.mutants.map(\.original)
        #expect(originals.filter { $0 == ">" }.count == 6)
        #expect(originals.filter { $0 == ">=" }.count == 2)
        #expect(originals.filter { $0 == "<" }.count == 1)
        #expect(originals.filter { $0 == "==" }.count == 2)
        #expect(result.instrumented.contains("continue outer"))
        #expect(result.ignored.isEmpty)
    }

    /// 外側と内側の両方にミュータントがあるとき、変異版の側は「元の式 + 1件の変更」だけになる。
    @Test func innerSwitchesOnlyInOriginalBranch() throws {
        let source = "func f(_ a: Int, _ b: Int) -> Bool { a > b && b > 0 }\n"
        let result = process(source)
        expectValidInstrumentation(result)
        let and = try #require(result.mutants.first { $0.original == "&&" })
        #expect(and.mutatedExpression == "(a > b) || (b > 0)")
        #expect(result.instrumented.contains("(__xcmutate.isOn(\(and.id)) ? ((a > b) || (b > 0)) : ((__xcmutate.isOn("))
    }

    @Test func implicitReturnGetterAndClosure() {
        let result = process("""
        struct S {
            var count = 0
            var isEmpty: Bool { count == 0 }
            func isAdult(_ a: Int) -> Bool { a >= 18 }
            let check: (Int) -> Bool = { $0 > 1 }
        }

        """)
        expectValidInstrumentation(result)
        #expect(result.mutants.count == 3)
    }

    @Test func stringInterpolationAndSubscript() {
        let result = process(options: expressionOnly, """
        func f(_ count: Int, _ values: inout [Int], _ i: Int) -> String {
            values[i > 0 ? i : 0] = 1
            return "\\(count > 0)"
        }

        """)
        expectValidInstrumentation(result)
        #expect(Set(result.mutants.map(\.operator)) == [.boundary, .ternarySwap])
        #expect(result.mutants.count == 3)
    }

    @Test func tryAndAwaitStayOutsideOfSwitch() {
        let result = process("""
        func parse() throws -> Int { 1 }
        func count() async -> Int { 1 }
        func f() async throws -> Bool {
            if try parse() > 0, await count() > 10 { return true }
            return false
        }

        """)
        expectValidInstrumentation(result)
        #expect(result.instrumented.contains("if try (__xcmutate.isOn(0) ? (parse() >= 0) : (parse() > 0)), await (__xcmutate.isOn(1) ? (count() >= 10) : (count() > 10))"))
    }
}

@Suite("複数行の式")
struct FlattenTests {
    @Test func multiLineExpressionKeepsLineNumbers() throws {
        let source = """
        func f(_ a: Int, _ b: Int) -> Bool {
            return a > 0 && // first
                b < 1 &&
                /* block */ a != b
        }

        """
        let result = process(source)
        expectValidInstrumentation(result)
        #expect(!result.verification.lineCountChanged)
        #expect(result.mutants.allSatisfy { !$0.mutatedExpression.contains("\n") })
        #expect(result.mutants.allSatisfy { !$0.mutatedExpression.contains("//") })
    }

    @Test func multiStatementClosureGetsSemicolons() throws {
        let source = """
        func f(_ items: [Int], _ ok: Bool) -> Bool {
            return ok && items.allSatisfy { v in
                let doubled = v * 2
                return doubled >= 0
            }
        }

        """
        let result = process(source)
        expectValidInstrumentation(result)
        let and = try #require(result.mutants.first { $0.original == "&&" })
        #expect(and.mutatedExpression == "ok || items.allSatisfy { v in let doubled = v * 2; return doubled >= 0 }")
    }

    @Test func multiLineStringLiteralCannotBeFlattened() {
        let result = generate("""
        func f(_ c: Bool, _ d: Bool) -> Bool {
            c && d == (\"\"\"
            a
            \"\"\" == "b")
        }

        """)
        // `d == (…)` holds the literal and cannot be put on one line; so cannot `c && …` as a whole
        #expect(result.mutants.isEmpty)
        #expect(Set(ignoredReasons(result)) == [.cannotFlatten])
    }

    /// A ternary with a multi-line string in a branch is mutated all the same: only the condition is rewritten.
    @Test func ternaryWithAMultiLineBranchIsMutated() throws {
        let result = process("""
        func f(_ c: Bool) -> String {
            c ? \"\"\"
            a
            \"\"\" : "b"
        }

        """)
        #expect(result.mutants.only?.operator == .ternarySwap)
        expectValidInstrumentation(result)
    }
}
