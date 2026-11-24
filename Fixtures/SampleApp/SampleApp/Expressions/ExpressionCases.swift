import Foundation

// 7.2 式の形・テキスト処理で壊れやすいもの（#308・#262・#160・README の前提）。
enum Expressions {
    // T1: 暗黙の return（関数・getter・1式のクロージャ）
    static func isAdult(_ age: Int) -> Bool { age >= 18 }  // @case T1-func

    struct Stack {
        var count = 0
        var isEmpty: Bool { count == 0 }  // @case T1-getter
    }

    static let isEven: (Int) -> Bool = { $0 % 2 == 0 }  // @case T1-closure

    // T2: 暗黙の return の関数で、本体の式が関数呼び出し（文の削除の対象にしない。#262）
    static func calculate() -> Int { 42 }
    static func total() -> Int { calculate() }  // @case T2

    // T3: else 側が比較の三項、三項の入れ子
    static func pick(_ registered: Bool, _ a: Bool, _ b: Int, _ c: Int) -> Bool {
        return registered ? a : b > c  // @case T3-cmp
    }

    static func nested(_ a: Bool, _ b: Bool) -> Int { a ? (b ? 1 : 2) : 3 }  // @case T3-nested

    // T4: 比較の前の行に日本語のコメント・日本語の文字列リテラル・絵文字がある
    static func label(_ count: Int, _ limit: Int) -> String {
        // 上限を超えたら「多い」と表示する 🎉🇯🇵
        let prefix = "件数👨‍👩‍👧:"
        if count > limit { return prefix + "多い" }  // @case T4
        return prefix + "少ない"  // @case RV-label-less
    }

    // T5: 同じテキストの式が同じブロックに2回ある（2回目だけテストで検出できる）
    static func twice(_ a: Int, _ b: Int) -> Int {
        var log = 0
        if a > b { log += 0 }  // @case T5-first
        if a > b { return 1 }  // @case T5-second
        return log  // @case RV-twice-log
    }

    // T6: 同じテキストの副作用の文が同じブロックに2回ある（文の削除の対象）
    static func appendTwice() -> [String] {
        var log: [String] = []
        log.append("x")  // @case T6-first
        log.append("x")  // @case T6-second
        return log  // @case RV-appendTwice
    }

    // T7: 演算子の前後に空白が無い、`;` で1行に複数の文
    static func tight(_ a: Int, _ b: Int) -> Int { let x = a>b ? 1 : 0; let y = a<b ? 1 : 0; return x - y }  // @case T7

    // T8: 整数リテラルと演算子の多い長い式（型チェックが時間内に終わる）
    static func longCondition(_ a: Int, _ b: Int, _ c: Int, _ d: Int, _ e: Int, _ f: Int) -> Bool {
        a + b * 2 - c / 3 > d + 1 && e * 4 <= f - 2  // @case T8
    }

    // T9: オプショナルを含む比較
    struct User { var age: Int }

    static func canVote(_ user: User?) -> Bool { (user?.age ?? 0) > 17 }  // @case T9-coalesce

    static func positiveFlag(_ x: Int?) -> Int {
        if case .some(let v) = x, v > 0 { return 1 }  // @case T9-ifcase
        return 0
    }

    // T10: 文字列補間の中
    static func describe(_ count: Int) -> String { "hasItems=\(count > 0)" }  // @case T10

    // T11: 代入の左辺の添字の中の式は対象、`&` の対象は対象外
    static func mark(_ values: [Int], at i: Int) -> [Int] {
        var copy = values
        copy[i > 0 ? i : values.count - 1] = 1  // @case T11-subscript
        return copy  // @case RV-mark
    }

    static func swapped(_ a: Int, _ b: Int) -> (Int, Int) {
        var x = a
        var y = b
        swap(&x, &y)  // @case T11-inout
        return (x, y)
    }
}
