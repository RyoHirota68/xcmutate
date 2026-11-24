import Foundation
@testable import MutatorCore
import Testing

/// 埋め込んだプログラムを実際にコンパイル・実行し、
/// 「スイッチで1件を有効にした結果」と「そのミュータント1件だけを素朴に書き換えたプログラムの結果」が
/// 一致することを確かめる（入れ子の組み立てが正しいことの検査）。
@Suite("実行による検査（swiftc）", .serialized)
struct ExecutionOracleTests {
    static let swiftc = "/usr/bin/xcrun"
    static var available: Bool { FileManager.default.isExecutableFile(atPath: swiftc) }

    static let program = """
    // 日本語のコメント: 位置がずれないこと 🎌
    func classify(_ a: Int, _ b: Int, _ items: [Int]) -> [String] {
        var out: [String] = []
        if a > b && !items.isEmpty {
            out.append("gt:\\(items.filter { $0 > b }.count == 0)")
        }
        let ok = a >= b ? true : false
        let long = a > 0 &&
            b < 1 // コメント
        out.append("\\(ok)\\(long)")
        for v in items where v != a {
            guard v >= 0 else { continue }
            out.append(v <= b ? "le" : "gt")
        }
        if let last = items.last, last == a || last < 0 { out.append("last") }
        let r = { (x: Int) -> Bool in
            let doubled = x * 2
            return doubled > a
        }(b)
        out.append(r ? "r" : "nr")
        out.append(a > b ? (b > 0 ? "x" : "y") : "z")
        return out
    }
    enum Kind { case has, no, unknown }
    func scan(_ xs: [Int], _ key: String?) -> Kind {
        var hasUnknown = false
        for x in xs {
            guard let k = key, k.lowercased() == "go", x != 99 else { return .no }
            switch x {
            case 0: continue
            case 1: hasUnknown = true
            default: break
            }
            if x > 5 { return .has }
        }
        return hasUnknown ? .unknown : .no
    }
    // Optional チェーン・if / switch の式・末尾クロージャ・暗黙のメンバー式・算術・?? ・min / max
    struct Person { var name: String; var tags: [String] }
    enum Level { case low, high }
    func probe(_ p: Person?, _ n: Int?, _ flags: [Bool]) -> String {
        let lower = p?.name.lowercased().hasPrefix("a")
        let desc = p?.name.uppercased().debugDescription ?? "-"
        let count = p?.tags.first?.lowercased().count ?? 0
        let v = n ?? 7
        let m = min(max(v, 0), 10) * 2 + 1
        let trues = flags.filter { $0 }.count
        let level: Level = v > 5 ? .high : .low
        let kind = if v > 5 { "big" } else { "small" }
        let sw = switch v { case 0: "zero"; default: "other" }
        guard flags.contains(true) else { return "none \\(m) \\(level)" }
        if p?.tags.isEmpty ?? true { return "notags \\(kind)" }
        return "\\(String(describing: lower)) \\(desc) \\(count) \\(m) \\(trues) \\(kind) \\(sw) \\(level)"
    }
    func isEnabled(_ flags: [Bool]) -> Bool { flags.contains(true) }
    // empty-body, compound-assignment, try-optional-nil, condition-constant, switch-case-removal
    struct Boom: Error {}
    final class Acc {
        var total = 0
        var on = false
        func bump(_ n: Int) {
            on = true
            total += n // 複合代入
            total *= 2
        }
        func reset() { total = 0 }
        func parse(_ s: String) throws -> Int { guard let v = Int(s) else { throw Boom() }; return v }
        func read(_ s: String) -> Int {
            let v: Int? = try? parse(s)
            // 型の注釈は、素朴に `nil` に書き換えた版（比較の相手）をコンパイルできるようにするため
            guard let w: Int = try? parse(s + "0") else { return -1 }
            if w > 100 { reset() }
            return (v ?? 0) + w
        }
        func grade() -> String {
            switch total {
            case 0, 2: return "low"
            case 4: return "four"
            default: return "many"
            }
        }
    }
    func label(_ k: Kind) -> String { switch k { case .has: return "H"; case .no: return "N"; case .unknown: return "U" } }
    // return-case, implicit-return-value, closure-statement-removal
    enum Outcome { case none, value(Int), failure(String) }
    func decide(_ x: Int?, _ limit: Int) -> Outcome {
        guard let x else { return .none }
        if x < 0 { return .failure("neg") }
        if x > limit { return .value(limit) }
        return .value(x)
    }
    struct Box {
        var items: [Int]
        var total: Int { items.reduce(0, +) }
        var first: Int? { items.first }
        func names() -> [String] { items.map { String($0) } }
        subscript(i: Int) -> Int? { items.dropFirst(i).first }
        func collect(_ limit: Int) -> [Int] {
            var result: [Int] = []
            items.forEach { element in result.append(element) }
            let take: (Int) -> Int? = { value in
                guard value > 0 else { return nil }
                result.append(value)
                for step in 0..<value { result.append(step) }
                return value
            }
            _ = take(limit)
            return result
        }
    }
    func show(_ o: Outcome) -> String { switch o { case .none: return "none"; case let .value(v): return "v\\(v)"; case let .failure(m): return "f" + m } }
    for (a, b, items) in [(3, 1, [1, 2, 3]), (1, 3, [0, -1, 5]), (2, 2, []), (0, -1, [0]), (-2, 0, [4, -2])] {
        print(classify(a, b, items).joined(separator: ","))
    }
    for (xs, key) in [([0, 1, 7], "GO"), ([1, 2], "go"), ([3], "no"), ([0, 99], "Go"), ([2, 1], nil)] as [([Int], String?)] {
        print(label(scan(xs, key)))
    }
    for (p, n, flags) in [(Person(name: "Ab", tags: ["X"]), 3, [true]), (nil, nil, [false]), (Person(name: "b", tags: []), 0, [true, false]),
                          (Person(name: "ab", tags: ["Yz", "q"]), 12, [true, true])] as [(Person?, Int?, [Bool])] {
        print(probe(p, n, flags), isEnabled(flags))
    }
    let acc = Acc()
    for s in ["0", "x", "1", "22"] { acc.bump(acc.read(s)); print(acc.total, acc.on, acc.grade()) }
    for (x, limit) in [(nil, 1), (-1, 1), (5, 3), (2, 3)] as [(Int?, Int)] { print(show(decide(x, limit))) }
    let box = Box(items: [3, 1])
    print(box.total, box.first ?? -1, box.names(), box[0] ?? -1, box[5] ?? -1, box.collect(2))

    """

    func compileAndRun(_ source: String, in dir: URL, name: String, environment: [String: String] = [:], warningsAsErrors: Bool = true) throws -> String {
        let src = dir.appendingPathComponent("\(name).swift")
        let exe = dir.appendingPathComponent(name)
        try source.write(to: src, atomically: true, encoding: .utf8)
        let compile = try #require(runProcess(Self.swiftc, ["swiftc", "-swift-version", "6"] + (warningsAsErrors ? ["-warnings-as-errors"] : []) + ["-o", exe.path, src.path]))
        try #require(compile.status == 0, "compile failed for \(name):\n\(compile.output)\n\(source)")
        let run = try #require(runProcess(exe.path, [], environment: environment))
        try #require(run.status == 0, "run failed for \(name): \(run.output)")
        return run.output
    }

    @Test(.enabled(if: available), .timeLimit(.minutes(10)))
    func switchesBehaveLikeSingleMutations() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xcmutate-oracle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // 既定で無効の演算子も含めて全部の演算子で確かめる
        let result = FileProcessor(options: GeneratorOptions(operators: Set(MutationOperator.allCases)))
            .process(source: Self.program, file: "main.swift", firstID: 0)
        expectValidInstrumentation(result)
        #expect(result.mutants.count >= 20)

        let original = try compileAndRun(Self.program, in: dir, name: "original")
        let neutral = try compileAndRun(result.instrumented, in: dir, name: "instrumented")
        #expect(neutral == original, "全ミュータント無効の結果が元のプログラムと違う")

        let instrumentedExe = dir.appendingPathComponent("instrumented").path
        var killedByOutput = 0
        for mutant in result.mutants {
            let viaSwitch = try #require(runProcess(instrumentedExe, [], environment: [Instrumenter.environmentVariable: String(mutant.id)]))
            // 素朴に書き換えた版は、文の削除で「変更されない var」などの警告が出うるので警告をエラーにしない。
            let expected = try compileAndRun(applySingle(Self.program, mutant), in: dir, name: "m\(mutant.id)", warningsAsErrors: false)
            #expect(viaSwitch.output == expected, "mutant \(mutant.id) (\(mutant.operator.rawValue) at line \(mutant.start.line)) differs")
            if expected != original { killedByOutput += 1 }
        }
        // ほとんどのミュータントは出力を変える（スイッチが本当に効いている）。
        #expect(killedByOutput >= result.mutants.count / 2)
        #expect(result.mutants.contains { $0.isStatement })
        for op in [MutationOperator.emptyBody, .compoundAssignment, .switchCaseRemoval, .tryOptionalNil, .conditionConstant, .guardRemoval,
                   .returnCase, .implicitReturnValue, .closureStatementRemoval] {
            #expect(result.mutants.contains { $0.operator == op }, "no \(op.rawValue) mutant in the oracle program")
        }

        // 到達の記録: 全ミュータント無効で実行すると、評価されたスイッチの ID が `R <ID>` で1回ずつ書かれる。
        let tracePath = dir.appendingPathComponent("neutral.trace").path
        let traced = try #require(runProcess(instrumentedExe, [], environment: [Instrumenter.traceEnvironmentVariable: tracePath]))
        #expect(traced.output == original, "記録しても出力が変わらない")
        let neutralLines = try String(contentsOfFile: tracePath, encoding: .utf8).split(separator: "\n")
        #expect(neutralLines.allSatisfy { $0.hasPrefix("R ") })
        #expect(Set(neutralLines).count == neutralLines.count, "ID ごとに1回だけ書く")
        let reached = Set(neutralLines.compactMap { Int($0.dropFirst(2)) })
        #expect(reached.count >= result.mutants.count * 3 / 4)

        // 有効化の記録: 有効にした ID は `A <ID>` で書かれる。
        let target = try #require(result.mutants.first { reached.contains($0.id) })
        let activePath = dir.appendingPathComponent("active.trace").path
        _ = runProcess(instrumentedExe, [], environment: [
            Instrumenter.traceEnvironmentVariable: activePath, Instrumenter.environmentVariable: String(target.id),
        ])
        let activeLines = try String(contentsOfFile: activePath, encoding: .utf8).split(separator: "\n")
        #expect(activeLines.contains("A \(target.id)"))
    }
}
