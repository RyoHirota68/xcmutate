import StateAcrossSuites
import XCTest

/// Does not run `reload`, and fails when the limit that `ALimitsTests` left is not 10.
final class BValidatorTests: XCTestCase {
    func testTheLimitIsTen() {
        XCTAssertFalse(isValid(15))
        XCTAssertFalse(isValid(10))
        XCTAssertTrue(isValid(9))
    }
}
