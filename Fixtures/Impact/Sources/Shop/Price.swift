public enum Price {
    public static func total(_ items: [Int]) -> Int { items.isEmpty ? 0 : items.reduce(0, +) }
    public static func discounted(_ total: Int) -> Int { total > 100 ? total - 10 : total }
}
