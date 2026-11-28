public struct Cart {
    public var items: [Int] = []
    public init(items: [Int] = []) { self.items = items }
    public var count: Int { items.count }
    public var isEmpty: Bool { items.count == 0 }
}
