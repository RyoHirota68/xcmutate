import XCTest
@testable import OnceOutsideGate

/// Runs first, calls nothing of `price(_:)` and switches its cache on: what an app's set-up does once per process.
final class AWarmupTests: XCTestCase {
    func testWarmUp() {
        Settings.cacheEnabled = true
        XCTAssertTrue(Settings.cacheEnabled)
    }
}
