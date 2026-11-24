import XCTest
@testable import SampleApp

/// XCTest features that talk to the test session of xcodebuild.
final class ActivityTests: XCTestCase {
    func testActivity() {
        let value = XCTContext.runActivity(named: "step one") { _ in 1 + 1 }
        XCTAssertEqual(value, 2)
    }
}
final class AttachmentTests: XCTestCase {
    func testAttachment() {
        let attachment = XCTAttachment(string: "hello")
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertTrue(true)
    }
}
final class ExpectedFailureTests: XCTestCase {
    func testExpectedFailure() {
        XCTExpectFailure("known") { XCTFail("expected") }
    }
}
final class MeasureTests: XCTestCase {
    func testMeasure() {
        // One iteration: the default of ten would add a quarter of a second to every run of the tests
        let options = XCTMeasureOptions()
        options.iterationCount = 1
        measure(options: options) { _ = (0..<1000).reduce(0, +) }
    }
}
