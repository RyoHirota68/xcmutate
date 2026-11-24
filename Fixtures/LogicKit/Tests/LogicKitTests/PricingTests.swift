import LogicKit
import Testing
import XCTest

final class SubtotalTests: XCTestCase {
    func testSubtotalMultipliesAndAdds() {
        XCTAssertEqual(Pricing.subtotal([LineItem(unitPrice: 100, quantity: 2), LineItem(unitPrice: 50, quantity: 1)]), 250)
    }

    func testLinesWithoutQuantityAreIgnored() {
        XCTAssertEqual(Pricing.subtotal([LineItem(unitPrice: 100, quantity: 0), LineItem(unitPrice: 70, quantity: -1), LineItem(unitPrice: 30, quantity: 1)]), 30)
    }

    func testTaxCountsTaxableLinesOnly() {
        let items = [LineItem(unitPrice: 1000, quantity: 1), LineItem(unitPrice: 500, quantity: 2, isTaxable: false)]
        XCTAssertEqual(Pricing.tax(items, ratePercent: 10), 100)
    }
}

@Suite struct DiscountTests {
    @Test(arguments: [(4_999, 0), (5_000, 250), (9_999, 499), (10_000, 1_000)])
    func discountSteps(subtotal: Int, expected: Int) {
        #expect(Pricing.discount(for: subtotal) == expected)
    }

    @Test func totalAppliesDiscountAndTax() {
        let items = [LineItem(unitPrice: 6_000, quantity: 1)]
        #expect(Pricing.total(items, ratePercent: 10) == 6_000 - 300 + 600)
    }

    // The boundary at 3,000 and the empty order are not checked: mutants there survive on purpose.
    @Test func shippingIsChargedOnSmallOrders() {
        #expect(Pricing.shipping(for: 1_000, itemCount: 1) == 500)
        #expect(Pricing.shipping(for: 8_000, itemCount: 2) == 0)
    }
}
