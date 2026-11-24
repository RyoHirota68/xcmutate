// 7.8 テストの種類・実行基盤。
enum TestKinds {
    // X1: XCTest だけで検出する関数と、Swift Testing だけで検出する関数
    static func xcTestOnly(_ x: Int) -> Bool { x > 1 }  // @case X1-xctest
    static func swiftTestingOnly(_ x: Int) -> Bool { x < 1 }  // @case X1-swifttesting

    // X2: Swift Testing のパラメータ化テストで検出する
    static func parameterized(_ x: Int) -> Bool { x >= 1 }  // @case X2

    // X3: ミュータントで配列の範囲外アクセスになりクラッシュする
    static func element(_ xs: [Int], _ i: Int) -> Int { i < xs.count ? xs[i] : -1 }  // @case X3

    // X7: ホットループで変異した関数を 100 万回呼ぶ（無効時の実行時間がベースラインとほぼ同じこと）
    static func countMultiplesOfSeven(below n: Int) -> Int {
        var c = 0
        for i in 0..<n where isMultipleOfSeven(i) { c += 1 }  // @case CA-x7-count
        return c  // @case RV-countMultiples
    }

    static func isMultipleOfSeven(_ i: Int) -> Bool { i % 7 == 0 }  // @case X7
}

// X10: `==` だけを定義した型（Equatable に準拠しない）。`a == b` を `!=` に書き換えるとコンパイルできない。
// ツールはビルドの診断からこのミュータントを特定して外し（CompileError）、再ビルドする。
nonisolated struct Token {
    var raw: Int
}

nonisolated func == (l: Token, r: Token) -> Bool { l.raw == r.raw }  // @case X10-impl

enum Tokens {
    static func same(_ a: Token, _ b: Token) -> Bool { a == b }  // @case X10
}
