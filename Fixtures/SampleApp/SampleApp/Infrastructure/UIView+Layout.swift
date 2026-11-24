import UIKit

// X8: ファイル名に `+` を含む
extension UIView {
    func isWider(than other: UIView) -> Bool { bounds.width > other.bounds.width }  // @case X8-plus
}
