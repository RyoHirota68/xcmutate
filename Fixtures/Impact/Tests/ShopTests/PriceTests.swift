import XCTest
@testable import Shop

final class PriceTests: XCTestCase {
    func testTotal() { XCTAssertEqual(Price.total([1, 2, 3]), 6) }
    func testDiscount() { XCTAssertEqual(Price.discounted(200), 190); XCTAssertEqual(Price.discounted(50), 50) }
}
