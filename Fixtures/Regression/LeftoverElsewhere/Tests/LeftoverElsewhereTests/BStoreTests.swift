import XCTest
@testable import LeftoverElsewhere

/// Fails while the marker file exists, and does not remove it.
final class BStoreTests: XCTestCase {
    func testOne() {
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerPath))
        saveCount(0)
        XCTAssertTrue(isBig(5000))
        XCTAssertTrue(isSmall(1))
    }

    func testTwo() {
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerPath))
        saveCount(0)
        XCTAssertFalse(isBig(5))
        XCTAssertFalse(isSmall(30))
    }
}
