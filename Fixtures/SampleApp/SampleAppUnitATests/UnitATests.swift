import XCTest
@testable import SampleApp

/// 2つ目・3つ目のユニットテストのターゲット（スキーム SampleAppUnits）。こちらは XCTest。
@MainActor
final class UnitATests: XCTestCase {
    func testU1IsAdult() {
        XCTAssertTrue(UnitCases.isAdult(20))
        XCTAssertFalse(UnitCases.isAdult(19))
    }

    /// U2: 呼ぶだけで値を確かめない（検出するのはターゲット B）
    func testU2CallsOnly() {
        _ = UnitCases.clamp(-1)
    }

    /// U3: 構成の言語で期待値が変わる
    func testU3Yes() {
        XCTAssertEqual(UnitCases.yes(), UnitCases.isJapanese() ? "はい" : "yes")
    }

    /// U4: 空でないことしか確かめない
    func testU4Label() {
        XCTAssertFalse(UnitCases.label(1).isEmpty)
        XCTAssertFalse(UnitCases.label(2).isEmpty)
    }
}
