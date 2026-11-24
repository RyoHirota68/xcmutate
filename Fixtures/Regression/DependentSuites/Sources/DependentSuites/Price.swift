public final class Registry {
    public static let shared = Registry()
    public var ready = false
}

// The tests never try the boundaries 100 and 10: both mutants survive a run of all tests.
public func isExpensive(_ price: Int) -> Bool { price >= 100 }
public func isCheap(_ price: Int) -> Bool { price < 10 }
