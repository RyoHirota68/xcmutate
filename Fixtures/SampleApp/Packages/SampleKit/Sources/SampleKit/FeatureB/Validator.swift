// X8: 同名ファイル（アプリ側の SampleApp/Infrastructure/FeatureA/Validator.swift）。ID が衝突しないこと。
// Swift は1つのモジュールに同名のファイルを置けないため、別のモジュール（このパッケージ）に置く。
public enum FeatureBValidator {
    public static func isValid(_ s: String) -> Bool { s.count <= 5 }  // @case X8-featureB
}
