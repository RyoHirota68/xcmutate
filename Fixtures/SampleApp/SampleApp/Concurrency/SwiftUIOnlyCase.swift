import SwiftUI

// A7: `import SwiftUI` だけのファイル
enum SwiftUIOnlyCase {
    static func isWide(_ width: CGFloat) -> Bool { width > 600 }  // @case A7-swiftui
}
