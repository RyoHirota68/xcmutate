import Foundation
import Observation
import SwiftUI

// 7.5 SwiftUI・result builder・マクロ（README の制約・#307）。

// S3・S4: @Observable クラス
@Observable final class CounterModel {
    static let initialCount = 0
    var count = CounterModel.initialCount
    // S4: アタッチドマクロが付いた型のプロパティの初期値
    var isReady = CounterModel.initialCount > 0  // @case S4

    // S3: ViewModel のメソッドの比較
    func canDecrement() -> Bool { count > 0 }  // @case S3
}

// S5: buildEither を持たない独自の @resultBuilder
@resultBuilder enum TagBuilder {
    static func buildBlock(_ parts: [String]...) -> [String] { parts.flatMap { $0 } }  // @case SE-buildBlock
    static func buildExpression(_ tag: String) -> [String] { [tag] }  // @case IR-buildExpression
    static func buildOptional(_ part: [String]?) -> [String] { part ?? [] }  // @case IR-buildOptional
}

nonisolated struct Person: Sendable {
    var age: Int
}

enum SwiftUICases {
    @TagBuilder static func tags(for n: Int) -> [String] {
        "n=\(n)"
        "big=\(n > 10)"  // @case S5
        if n == 0 { "zero" }  // @case S5-if
    }

    // S6: #Predicate の中（マクロの引数は対象外）
    static let adults = #Predicate<Person> { $0.age > 18 }  // @case S6

    // S8: View から切り出したテスト可能な関数
    static func badgeText(count: Int) -> String { count > 99 ? "99+" : "\(count)" }  // @case S8
}

struct BadgeView: View {
    let count: Int
    let showsZero: Bool

    var body: some View {
        Text(SwiftUICases.badgeText(count: count))  // @case SE-badge-body
            .opacity(showsZero || count != 0 ? 1 : 0)  // @case S2-badge
    }
}

// S7: #Preview の中（対象外）
#Preview { BadgeView(count: 5, showsZero: true) }  // @case S7
