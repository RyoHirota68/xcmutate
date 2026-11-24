import XCTest
@testable import LeftoverElsewhere

/// The only place that removes the marker file. It runs first in a run of all tests.
final class ACleanTests: XCTestCase {
    func testClean() {
        try? FileManager.default.removeItem(atPath: markerPath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerPath))
    }
}
