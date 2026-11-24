import Foundation

// 7.1 ネストした位置（Muter #322・#308・#303・#117 の回帰テスト）。
// 各行末の `// @case <ID>` を expected.json が参照する。
enum Nested {
    // N1: 関数本体の直下の比較
    static func compareCode(_ a: Int, _ b: Int) -> Int {
        if a > b { return 1 }  // @case N1
        return 0
    }

    // N2: 外側の文と内側のクロージャの両方に比較がある
    static func filterAbove(_ x: Int, _ items: [Int], limit: Int) -> [Int] {
        if x > 0 {  // @case N2-outer
            return items.filter { $0 > limit }  // @case N2-inner
        }
        return []
    }

    // N3: 標準ライブラリのクロージャ引数の中
    static func byPriority(_ tasks: [(name: String, priority: Int)]) -> [String] {
        tasks.sorted { $0.priority < $1.priority }.map(\.name)  // @case N3-sorted
    }

    static func removing(_ values: [Int], _ y: Int) -> [Int] {
        var copy = values
        copy.removeAll { $0 == y }  // @case N3-removeAll
        return copy  // @case RV-removing
    }

    static func allNonNegative(_ values: [Int]) -> Bool {
        values.allSatisfy { $0 >= 0 }  // @case N3-allSatisfy
    }

    static func flags(_ values: [Int]) -> [Bool] {
        values.map { $0 > 1 }  // @case N3-map
    }

    // N4: for の本体の guard と、外側の関数本体の比較
    static func countNonNegative(_ values: [Int], cap: Int) -> Int {
        var count = 0
        for v in values {
            guard v >= 0 else { continue }  // @case N4-inner
            count += 1  // @case CA-n4-count
        }
        return count > cap ? -1 : count  // @case N4-outer
    }

    // N5: 二重の for の両方の階層に比較
    static func pairsBelow(_ xs: [Int], _ ys: [Int], threshold: Int) -> Int {
        var n = 0
        for x in xs where x > threshold {  // @case N5-outer
            for y in ys {
                if y < x { n += 1 }  // @case N5-inner
            }
        }
        return n  // @case RV-pairsBelow
    }

    // N6: while と repeat-while
    static func triangular(_ n: Int) -> Int {
        var i = 0
        var total = 0
        while i < n { i += 1; total += i }  // @case N6-while
        return total  // @case RV-triangular
    }

    static func countdown(from n: Int) -> [Int] {
        var out: [Int] = []
        var i = n
        repeat { out.append(i); i -= 1 } while i > 0  // @case N6-repeat
        return out  // @case RV-countdown
    }

    // N7: if-let / guard-let の条件の中
    static func withinTolerance(_ values: [Int], total: Int, tol: Int) -> Int {
        if let last = values.last, last >= total - tol { return 1 }  // @case N7-iflet
        return 0
    }

    static func atLeastFour(_ y: Int?) -> Int {
        guard let x = y, x > 3 else { return 0 }  // @case N7-guardlet
        return x  // @case RV-atLeastFour
    }

    // N8: 即時実行クロージャの初期化子
    static func attempts(_ data: [Int]?) -> Int {
        let attempts: Int = {
            guard let d = data, d.count == 4 else { return 0 }  // @case N8
            return d.count
        }()
        return attempts  // @case RV-attempts
    }

    // N9: forEach の本体（#117）
    static func countPositive(_ values: [Int]) -> Int {
        var n = 0
        values.forEach { if $0 > 0 { n += 1 } }  // @case N9
        return n  // @case RV-countPositive
    }

    // N10: for-in の where と switch の case の where
    static func countPositiveWhere(_ xs: [Int]) -> Int {
        var n = 0
        for x in xs where x > 0 { n += 1 }  // @case N10-for
        return n  // @case RV-countPositiveWhere
    }

    static func sign(_ v: Int) -> String {
        switch v {
        case let p where p > 0: return "positive"  // @case N10-case
        case 0: return "zero"  // @case RV-sign-zero
        default: return "negative"  // @case RV-sign-negative
        }
    }

    // N11: defer の中
    static func drain(_ count: Int) -> [String] {
        var log: [String] = []
        func run() {  // @case EB-run
            defer { if count > 0 { log.append("cleanup") } }  // @case N11
            log.append("run")  // @case N11-run
        }
        run()  // @case N11-call
        return log  // @case RV-drain
    }

    // N12: ラベル付きループ（ラベルが壊れないこと）
    static func rowsWithinLimit(_ grid: [[Int]], limit: Int) -> Int {
        var rows = 0
        outer: for row in grid {
            for cell in row {
                if cell > limit { continue outer }  // @case N12
            }
            rows += 1  // @case CA-n12-rows
        }
        return rows  // @case RV-rows
    }

    // N13: ライブラリの呼び出しに渡す末尾クロージャ（テストで待つ）
    static func asyncCompare(_ a: Int, _ b: Int, completion: @escaping @Sendable (Bool) -> Void) {
        DispatchQueue.main.async { completion(a > b) }  // @case N13
    }
}
