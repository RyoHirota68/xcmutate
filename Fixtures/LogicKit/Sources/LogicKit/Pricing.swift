public struct LineItem: Sendable, Equatable {
    public var unitPrice: Int
    public var quantity: Int
    public var isTaxable: Bool

    public init(unitPrice: Int, quantity: Int, isTaxable: Bool = true) {
        self.unitPrice = unitPrice
        self.quantity = quantity
        self.isTaxable = isTaxable
    }
}

public enum Pricing {
    /// Sum of the lines; lines with a quantity of zero or less are ignored.
    public static func subtotal(_ items: [LineItem]) -> Int {
        var total = 0
        for item in items {
            if item.quantity <= 0 { continue }
            total += item.unitPrice * item.quantity
        }
        return total
    }

    /// Ten percent off from 10,000 upwards, five percent off from 5,000 upwards.
    public static func discount(for subtotal: Int) -> Int {
        if subtotal >= 10_000 { return subtotal / 10 }
        if subtotal >= 5_000 { return subtotal / 20 }
        return 0
    }

    /// Tax on the taxable lines only.
    public static func tax(_ items: [LineItem], ratePercent: Int) -> Int {
        let taxable = items.filter { $0.isTaxable && $0.quantity > 0 }
        return subtotal(taxable) * ratePercent / 100
    }

    public static func total(_ items: [LineItem], ratePercent: Int) -> Int {
        let sum = subtotal(items)
        return sum - discount(for: sum) + tax(items, ratePercent: ratePercent)
    }

    /// Free shipping from 3,000 upwards, or when there is nothing to ship.
    public static func shipping(for subtotal: Int, itemCount: Int) -> Int {
        if itemCount == 0 || subtotal >= 3_000 { return 0 }
        return 500
    }
}
