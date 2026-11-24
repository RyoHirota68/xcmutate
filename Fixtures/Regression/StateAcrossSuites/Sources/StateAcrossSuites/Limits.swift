/// A value that lives as long as the process and that the code under test reads.
public final class Limits {
    public static let shared = Limits()
    public private(set) var limit = 10

    /// The tests of this function (`ALimitsTests`) check only that the limit stays positive.
    public func reload(strict: Bool) {
        limit = strict ? 10 : 20
    }
}

/// Reads the limit. Its tests (`BValidatorTests`) never call `reload`, but they run after a test that does.
public func isValid(_ n: Int) -> Bool {
    return n < Limits.shared.limit
}
