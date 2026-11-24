import StateAcrossSuites
import XCTest

/// The only test that runs `reload`. It leaves the limit in the process for the suites that run after it.
final class ALimitsTests: XCTestCase {
    func testReloadKeepsAPositiveLimit() {
        Limits.shared.reload(strict: true)
        XCTAssertGreaterThan(Limits.shared.limit, 0)
    }
}
