import UIKit

// 7.7 等価ミュータント・テストの穴の確認。
enum Equivalence {
    // E1: `>` → `>=` は a == b のときどちらを返しても同じ（等価）
    static func maxOf(_ a: Int, _ b: Int) -> Int { a > b ? a : b }  // @case E1

    // E2: `<` → `<=` は 0 で同じ（等価）
    static func absInt(_ x: Int) -> Int { x < 0 ? -x : x }  // @case E2

    // E3: 境界値をテストしていない比較（テストは 1 と 10 でしか確かめない）
    static func isBulk(_ count: Int) -> Bool { count >= 3 }  // @case E3-boundary
    static func isExactlyThree(_ count: Int) -> Bool { count == 3 }  // @case E3-equality

    // E4: `animated: true` 引数（arid）
    static func close(_ controller: UIViewController) {
        controller.dismiss(animated: true)  // @case E4
    }

    // E5: テストから呼ぶが結果を検証しない
    static func weakCheck(_ x: Int) -> Bool { x > 10 }  // @case E5

    // E6: どのテストからも呼ばれない
    static func neverCalled(_ x: Int) -> Bool { x < 0 }  // @case E6
}
