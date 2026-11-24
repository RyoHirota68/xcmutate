internal import Foundation

// A7: `internal import Foundation` を使うファイル（ツールは import を足さない）
enum InternalImportCase {
    static func isBlank(_ s: String) -> Bool { s.trimmingCharacters(in: .whitespaces).count == 0 }  // @case A7-internal
}
