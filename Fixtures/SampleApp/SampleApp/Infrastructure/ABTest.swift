// 7.12 X12: 名前が `Test.swift` で終わる製品コード。以前は、名前だけでテストとみなして黙って対象から外していた。
// テストのフレームワークを import していないので、製品コードとして対象にする。
enum ABTest {
    static func bucket(for userID: Int) -> String { userID % 2 == 0 ? "A" : "B" }  // @case X12
}
