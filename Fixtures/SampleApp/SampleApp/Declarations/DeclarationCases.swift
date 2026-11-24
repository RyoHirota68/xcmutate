import Foundation
import SampleKit

// 7.3 型・宣言の文脈（#76・#114・推測した壊れ方）。

// D3: 条件付き準拠の where 句の `==` は型の制約なので書き換えない。
nonisolated struct Box<T> { var value: T }
extension Box: Equatable where T == String {}  // @case D3-conformance

// D7: ファイルのトップレベルの let
let fixtureLevel = 3
let isVerboseLevel = fixtureLevel > 3  // @case D7

// D2: プロトコル拡張のデフォルト実装の中の比較
protocol Scored { var score: Int { get } }
extension Scored {
    var isPassing: Bool { score >= 60 }  // @case D2
}
struct Exam: Scored { var score: Int }

// D4: 演算子の実装。本体は対象、宣言そのもの（`static func <`）は対象外
nonisolated struct Version: Comparable {
    var major: Int
    static func < (l: Version, r: Version) -> Bool { l.major < r.major }  // @case D4
}

// D15: プロパティラッパー。ラッパーの実装の中の比較は対象、属性の引数は対象外
@propertyWrapper struct Clamped {
    private(set) var value: Int
    private(set) var clampCount = 0
    let max: Int

    init(wrappedValue: Int, max: Int) {
        self.max = max
        self.value = wrappedValue
        clamp()  // @case SE-clamp-init
    }

    var wrappedValue: Int {
        get { value }  // @case IR-wrapped-get
        set { value = newValue; clamp() }  // @case SE-clamp-set
    }

    var projectedValue: Int { clampCount }  // @case IR-projected

    private mutating func clamp() {  // @case EB-clamp
        if value > max { value = max; clampCount += 1 }  // @case D15-impl
    }
}

struct Volume {
    @Clamped(max: 3 > 2 ? 10 : 20) var level: Int = 5  // @case D15-arg
}

enum Declarations {
    // D1: ジェネリック関数
    static func countBelow<T: Comparable>(_ values: [T], _ limit: T) -> Int {
        values.filter { $0 < limit }.count  // @case D1
    }

    // D3: ジェネリックの where 句（本体の比較は対象）
    static func isSame<T>(_ a: T, _ b: T) -> Bool where T: Equatable { a == b }  // @case D3-body

    // D5: 優先順位グループが別ファイル（Operators.swift）で宣言された独自演算子。ツールが同じモジュールのファイルから宣言を集めるので畳み込める
    static func closeEnough(_ a: Int, _ b: Int) -> Bool { a <~> b <= 1 }  // @case D5

    // D6: 型のメンバーの初期値、static let の初期値
    static let threshold = 10

    struct Config {
        var isLarge = Declarations.threshold > 10  // @case D6-member
        static let strict = Declarations.threshold >= 10  // @case D6-static
    }

    // D8: 既定の引数（internal の関数は対象、public の関数は対象外）
    static let retries = 3
    static func fetch(force: Bool = Declarations.retries > 3) -> Bool { force }  // @case D8
    public static func fetchPublic(force: Bool = Declarations.retries > 3) -> Bool { force }  // @case D8-public

    // D9: let の遅延初期化
    static func pickValue(_ a: Int, _ b: Int) -> Int {
        let x: Int
        if a > b { x = 1 } else { x = 2 }  // @case D9
        return x  // @case RV-pickValue
    }

    // D10: enum の raw value、@available、#available
    enum Level: Int { case low = 1, high = 2 }  // @case D10-raw

    @available(iOS 27, *)
    static func modern() -> Int { 1 }  // @case D10-available

    static func runtimeCheck() -> Int {
        if #available(iOS 27, *) { return 1 }  // @case D10-ifavailable
        return 0
    }

    // D11: `#if` の条件
    #if DEBUG && os(iOS)  // @case D11
    static let buildKind = "debug-ios"
    #else
    static let buildKind = "other"
    #endif

    // D12: 有効な `#if` の分岐の中の比較
    #if DEBUG
    static func debugOnlyCheck(_ x: Int) -> Bool { x > 5 }  // @case D12
    #endif

    // D13: 無効な `#if` の分岐の中の比較（コンパイルされないので実行されない）
    #if os(macOS)
    static func macOnly(_ x: Int) -> Bool { x > 5 }  // @case D13
    #endif

    // D14: ローカル SPM パッケージ（Packages/SampleKit）の関数を呼ぶ
    static func kitInRange(_ v: Int) -> Bool { isInRange(v, 1, 5) }  // @case SE-kit-range
    static func kitPositive(_ v: Int) -> Bool { isPositive(v) }  // @case SE-kit-positive
    // X8: パッケージ側の同名ファイルの関数
    static func featureBValid(_ s: String) -> Bool { FeatureBValidator.isValid(s) }  // @case SE-kit-featureB
}
