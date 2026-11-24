import Foundation
import XCTest

/// A test that uses a resource with a fixed name for a moment, like a test that listens on a fixed port: two test
/// processes on one Mac cannot both hold it.
final class LockTests: XCTestCase {
    func testExclusiveResource() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("xcmutate-regression-shared.lock").path
        let descriptor = open(path, O_CREAT | O_EXCL | O_WRONLY, 0o644)
        XCTAssertGreaterThanOrEqual(descriptor, 0, "the resource is in use by another process")
        guard descriptor >= 0 else { return }
        Thread.sleep(forTimeInterval: 0.7)
        close(descriptor)
        unlink(path)
    }
}
