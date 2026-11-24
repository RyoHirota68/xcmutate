// A7: import が1つも無いファイル（ツールは `fileprivate import Foundation` を足す）
enum NoImportCase {
    static func isZero(_ x: Int) -> Bool { x == 0 }  // @case A7-noimport
}
