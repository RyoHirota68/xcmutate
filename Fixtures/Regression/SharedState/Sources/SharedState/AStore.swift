public final class Store {
    public static let shared = Store()
    private var items: [String] = []

    public func add(_ item: String) {
        items.append(item)
    }

    public func count(of item: String) -> Int {
        return items.filter { $0 == item }.count
    }

    /// The mutant that removes this statement passes the tests (each test sees its own item once) and leaves
    /// the items of that run in the process.
    public func clear() {
        items.removeAll()
    }
}
