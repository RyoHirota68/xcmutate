import XCTest
@testable import DependentSuites

/// Runs first (suites run in alphabetical order) and leaves state that BPriceTests needs.
final class ASetupTests: XCTestCase {
    func testPrepare() {
        Registry.shared.ready = true
        XCTAssertTrue(Registry.shared.ready)
    }
}
