import XCTest
@testable import SampleApp

/// 7.7 等価ミュータント・テストの穴。
@MainActor
final class EquivalenceTests: XCTestCase {
    func testE1MaxOf() {
        XCTAssertEqual(Equivalence.maxOf(2, 1), 2)
        XCTAssertEqual(Equivalence.maxOf(1, 2), 2)
        XCTAssertEqual(Equivalence.maxOf(2, 2), 2)
    }

    func testE2AbsInt() {
        XCTAssertEqual(Equivalence.absInt(-2), 2)
        XCTAssertEqual(Equivalence.absInt(2), 2)
        XCTAssertEqual(Equivalence.absInt(0), 0)
    }

    /// 境界値（3）を確かめない。
    func testE3BoundaryNotTested() {
        XCTAssertFalse(Equivalence.isBulk(1))
        XCTAssertTrue(Equivalence.isBulk(10))
        XCTAssertTrue(Equivalence.isExactlyThree(3))
        XCTAssertFalse(Equivalence.isExactlyThree(1))
    }

    /// 呼ぶが結果を検証しない（アサーションの無いテスト）。
    func testE5NoAssertion() {
        _ = Equivalence.weakCheck(11)
    }
}
