import XCTest
@testable import SharedState

/// Ordinary tests of a singleton that is emptied in tearDown.
final class StoreTests: XCTestCase {
    override func tearDown() {
        Store.shared.clear()
    }

    func testAddA() {
        Store.shared.add("a")
        XCTAssertEqual(Store.shared.count(of: "a"), 1)
    }

    func testAddB() {
        Store.shared.add("b")
        XCTAssertEqual(Store.shared.count(of: "b"), 1)
    }

    func testCalc() {
        XCTAssertTrue(Calc.over1(500))
        XCTAssertFalse(Calc.over1(5))
        XCTAssertTrue(Calc.over2(500))
        XCTAssertTrue(Calc.over3(500))
    }
}
