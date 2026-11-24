// 7.11 本体と条件の演算子（empty-body・compound-assignment・switch-case-removal・try-optional-nil・condition-constant・guard-removal）と、
// 無効化コメントの演算子指定。意図的なテストの穴を残す（期待結果は expected.json）。

struct CaseParseError: Error {}

/// `other` is named by no `switch`: with it, the `default` of `weight` is reachable, and the original sources build
/// with warnings treated as errors ("default will never be executed" otherwise).
enum SizeKind { case small, medium, large, huge, unknown, other }

final class BodyCounter {
    private(set) var count = 0
    private(set) var isActive = false  // @case EB1-state
    private(set) var label = ""
    private(set) var history: [Int] = []

    // EB1: 代入だけで状態を更新する関数（文の削除の対象が無い）。テストが状態を確かめる
    func activate() {  // @case EB1
        isActive = true  // @case EB1-assign
    }

    // EB2: 同じ形だが、テストは呼ぶだけで状態を確かめない（生き残る）
    func rename(_ name: String) {  // @case EB2
        label = name
    }

    // EB3: 呼び出しの文だけの本体は、文の削除が1件ずつ扱うので、本体を空にするミュータントは作らない
    func activateTwice() {  // @case EB3
        activate()  // @case EB3-first
        activate()  // @case EB3-second
    }

    // EB4: 早期 return の guard と呼び出しだけの本体も作らない
    func activateIfNeeded() {  // @case EB4
        guard !isActive else { return }  // @case EB4-guard
        activate()  // @case EB4-call
    }

    // CA1: 複合代入（テストが値を確かめる）
    func add(_ n: Int) {  // @case CA1-body
        count += n  // @case CA1
    }

    // CA2: 0 でしか呼ばないので `-=` → `+=` を区別できない（生き残る）。本体を空にしても同じ
    func discount(_ n: Int) {  // @case CA2-body
        count -= n  // @case CA2
    }

    // CA3: 文字列の `+=`。右辺がリテラルなら作らない。変数なら作るが、`-=` は String に無いのでコンパイルできない
    func append(_ suffix: String) {  // @case CA3-body
        label += "-"  // @case CA3-literal
        label += suffix  // @case CA3-variable
    }

    // CA4: `*=` と `/=`
    func scale(_ factor: Int) {  // @case CA4-body
        count *= factor  // @case CA4
    }
}

enum BodyAndCondition {
    // SC1: default のある switch の case を1つずつ外す
    static func weight(_ kind: SizeKind) -> Int {
        switch kind {
        case .small: return 1  // @case SC1-small
        case .medium, .large: return 5  // @case SC1-multi
        case .huge: return 100  // @case SC1-untested
        case .unknown: return 0  // @case SC1-same-as-default
        default: return 0  // @case SC1-default
        }
    }

    // SC2: where 節のある case は対象にしない。default の無い switch も対象にしない
    static func bucket(_ n: Int, _ kind: SizeKind) -> String {
        switch n {
        case let x where x > 100: return "big"  // @case SC2-where
        case 0: return "zero"  // @case SC2-zero
        default: break  // @case SC2-default
        }
        switch kind {
        case .small: return "s"  // @case SC2-exhaustive-small
        case .medium, .large, .huge, .unknown, .other: return "other"  // @case SC2-exhaustive-rest
        }
    }

    static func parse(_ text: String) throws -> Int {
        guard let value = Int(text) else { throw CaseParseError() }  // @case TN-parse
        return value  // @case TN-parse-return
    }

    // TN1: `try?` の結果を使う（成功する入力でテストしている）
    static func parsedOrZero(_ text: String) -> Int {
        let value = try? parse(text)  // @case TN1
        return value ?? 0  // @case TN1-return
    }

    // TN2: テストは失敗する入力しか渡さないので、`try?` → `nil` を区別できない（生き残る）
    static func parsedOrMinusOne(_ text: String) -> Int {
        guard let value = try? parse(text) else { return -1 }  // @case TN2
        return value  // @case TN2-return
    }

    // TN3: 文としての `try?` と `_ =` への代入は、文の削除と同じなので作らない
    static func warmUp(_ text: String) -> Bool {
        _ = try? parse(text)  // @case TN3-discard
        return true  // @case TN3-return
    }

    // TN4: 値を返す関数の本体が式1つ（暗黙の return）
    static func parsed(_ text: String) -> Int? { try? parse(text) }  // @case TN4

    // CC1: 条件が1つの guard → true（guard-removal。早期 return しない）
    static func half(_ n: Int) -> Int {
        guard n > 0 else { return 0 }  // @case CC1
        return n / 2  // @case CC1-return
    }

    // CC2: 早期 return の結果が、続きを実行した結果と同じ（等価。生き残る）
    static func doubled(_ n: Int) -> Int {
        guard n != 0 else { return 0 }  // @case CC2
        return n * 2  // @case CC2-return
    }

    // CC3: if → false（condition-constant。本体を通らない）。条件が複数のときは最後の式の条件だけ
    static func clampNegative(_ n: Int, _ enabled: Bool) -> Int {
        var result = n
        if enabled, n < 0 { result = 0 }  // @case CC3
        return result  // @case CC3-return
    }

    // DC1: 無効化コメントで演算子を指定する（boundary だけ無効。他の演算子は作る）
    static func isAdult(_ age: Int, _ verified: Bool) -> Bool {
        // xcmutate:disable-next-line boundary -- the boundary is covered by an integration test
        return age >= 18 && verified  // @case DC1
    }

    // DC2: 知らない演算子名は警告になり、何も無効にしない
    static func isSenior(_ age: Int) -> Bool {
        // xcmutate:disable-next-line boundry
        return age >= 65  // @case DC2
    }

    // DC3: ブロックで演算子を指定して無効にし、enable で戻す
    static func inRange(_ n: Int) -> Bool {
        // xcmutate:disable boundary, logical-connector
        let ok = n > 0 && n < 10  // @case DC3-disabled
        // xcmutate:enable
        return ok && n != 5  // @case DC3-enabled
    }
}
