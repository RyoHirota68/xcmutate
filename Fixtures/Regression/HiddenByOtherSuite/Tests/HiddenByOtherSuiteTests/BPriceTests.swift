import XCTest
@testable import HiddenByOtherSuite

/// Passes by itself and after ASetupTests. With a mutant in `threshold()` it fails by itself (the default is
/// used and is wrong) and passes after ASetupTests (the custom value is used).
final class BPriceTests: XCTestCase {
    func testExpensive() { XCTAssertTrue(isExpensive(500)) }
    func testNotExpensive() { XCTAssertFalse(isExpensive(5)) }
}
