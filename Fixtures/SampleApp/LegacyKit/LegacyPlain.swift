// L2: import を1つも書かないファイル（同じモジュールの LegacyFormatting.swift は普通の `import Foundation`）
public enum LegacyPlain {
    public static func isEven(_ n: Int) -> Bool {
        n % 2 == 0  // @case L2
    }
}
