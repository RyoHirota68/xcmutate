// 7.12 X13: `exclude` の `!` で対象に戻すファイル（`SampleApp/Excluded/**` で外した後、`!…/Kept.swift` で戻す）。
enum Kept {
    static func isPositive(_ n: Int) -> Bool { n > 0 }  // @case X13-kept
}
