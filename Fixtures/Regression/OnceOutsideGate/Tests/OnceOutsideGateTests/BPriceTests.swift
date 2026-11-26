import XCTest
@testable import OnceOutsideGate

final class BPriceTests: XCTestCase {
    func testSmallOrder() { XCTAssertEqual(price(2), 20) }
    func testLargeOrder() { XCTAssertEqual(price(20), 180) }
}
