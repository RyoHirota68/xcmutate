import Foundation

// テスト計画の構成が2つ（日本語・英語）で、ユニットテストのターゲットが2つある場合のケース。
// スキーム SampleAppUnits（テスト計画 Units.xctestplan）で使う。既定のスキーム SampleApp のテスト（SampleAppTests）は
// このファイルを実行しないので、そちらではすべて NotReached になる。
enum UnitCases {
    // U1: ターゲット A（SampleAppUnitATests）のテストだけが検出する
    static func isAdult(_ age: Int) -> Bool {
        return age >= 20  // @case U1
    }

    // U2: ターゲット B（SampleAppUnitBTests）のテストだけが検出する（A は呼ぶが値を確かめない）
    static func clamp(_ value: Int) -> Int {
        return max(0, value)  // @case U2
    }

    // U3: 日本語の構成でだけ実行される分岐と、英語の構成でだけ実行される分岐
    static func yes() -> String {
        if isJapanese() {  // @case U3-if
            return "はい"  // @case U3-ja
        }
        return "yes"  // @case U3-en
    }

    static func isJapanese() -> Bool {
        Locale.preferredLanguages.first?.hasPrefix("ja") ?? false  // @case U3-lang
    }

    // U4: どちらのターゲットも実行するが、どちらも検出しない
    static func label(_ count: Int) -> String {
        return count > 1 ? "items" : "item"  // @case U4
    }

    // U5: どのテストも実行しない
    static func unused(_ a: Int) -> Bool {
        return a == 0  // @case U5
    }

    // U6: 添字が範囲を外れてクラッシュする（ターゲット B のテスト）
    static func total(_ values: [Int], count: Int) -> Int {
        var total = 0
        for index in 0..<count where index < values.count {  // @case U6
            total += values[index]  // @case U6-add
        }
        return total  // @case U6-return
    }
}
