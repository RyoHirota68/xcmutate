// 7.12 X14: テストのディレクトリにある、テストのフレームワークを import しない補助コード。
// 同じディレクトリにテストのフレームワークを import するファイルがあるので、テストの一部として対象から外す。
enum TestHelpers {
    static func isSmall(_ n: Int) -> Bool { n < 10 }
}
