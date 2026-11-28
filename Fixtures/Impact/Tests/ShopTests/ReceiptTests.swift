import XCTest
@testable import Shop

final class ReceiptTests: XCTestCase {
    func testReceipt() { XCTAssertEqual(Price.total(Cart(items: sampleItems()).items), 6) }
}
