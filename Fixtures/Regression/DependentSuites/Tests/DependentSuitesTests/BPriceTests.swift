import XCTest
@testable import DependentSuites

/// Passes in a run of all tests and fails when it is run by itself: it needs what ASetupTests left.
final class BPriceTests: XCTestCase {
    func testExpensive() {
        XCTAssertTrue(Registry.shared.ready, "needs ASetupTests to have run")
        XCTAssertTrue(isExpensive(500))
        XCTAssertTrue(isCheap(1))
    }

    func testNotExpensive() {
        XCTAssertTrue(Registry.shared.ready, "needs ASetupTests to have run")
        XCTAssertFalse(isExpensive(5))
        XCTAssertFalse(isCheap(50))
    }
}
