// X8: 別フォルダの同名ファイル（Packages/SampleKit/Sources/SampleKit/FeatureB/Validator.swift）。ID が衝突しないこと
enum FeatureAValidator {
    static func isValid(_ s: String) -> Bool { s.count >= 3 }  // @case X8-featureA
}
