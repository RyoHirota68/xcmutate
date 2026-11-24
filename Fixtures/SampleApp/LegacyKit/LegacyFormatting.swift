import Foundation

// L1: Swift 5 モード・InternalImportsByDefault 無しのモジュール（普通の `import Foundation`）。
// 同じモジュールの LegacyPlain.swift は import を書かないので、ツールが import を足すと
// 「ambiguous implicit access level for import of 'Foundation'」のエラーになる（以前あった不具合の再発防止）。
public enum LegacyFormatting {
    public static func padded(_ n: Int) -> String {
        n < 10 ? "0\(n)" : String(n)  // @case L1
    }

    public static func trimmedName(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespaces)  // @case L1-trim
    }
}
