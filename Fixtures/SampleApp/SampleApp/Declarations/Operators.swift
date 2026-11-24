// D5: 独自の優先順位グループを持つ独自演算子。
// 同じファイルの中では優先順位が分かるので畳み込める（対象にする）。
precedencegroup DistancePrecedence {
    higherThan: ComparisonPrecedence
    lowerThan: AdditionPrecedence
}

infix operator <~> : DistancePrecedence

nonisolated func <~> (l: Int, r: Int) -> Int { abs(l - r) }  // @case SE-abs

enum Distances {
    static func withinOne(_ a: Int, _ b: Int) -> Bool { a <~> b <= 1 }  // @case D5-samefile
}
