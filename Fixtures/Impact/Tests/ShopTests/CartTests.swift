import XCTest
@testable import Shop

final class CartTests: XCTestCase {
    func testCount() { XCTAssertEqual(Cart(items: [1, 2]).count, 2) }
    func testEmpty() { XCTAssertTrue(Cart().isEmpty); XCTAssertFalse(Cart(items: [1]).isEmpty) }
}
