import XCTest
@testable import HiddenByOtherSuite

/// Runs first and leaves a custom threshold that equals the default.
final class ASetupTests: XCTestCase {
    func testPrepare() {
        Config.shared.custom = 100
        XCTAssertEqual(Config.shared.custom, 100)
    }
}
