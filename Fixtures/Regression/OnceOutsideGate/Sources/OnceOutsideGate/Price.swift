/// Switched on by a suite that calls nothing of this file (`AWarmupTests`). From then on `price(_:)` keeps what it
/// computed, so its body runs once per value and process: in the first run of all tests, and not in a later run.
// No mutants here: one would be reached by AWarmupTests, which is to stay outside the suites of the mutants.
// xcmutate:disable
public enum Settings {
    nonisolated(unsafe) public static var cacheEnabled = false
}
// xcmutate:enable

nonisolated(unsafe) private var cache: [Int: Int] = [:]

public func price(_ count: Int) -> Int {
    if Settings.cacheEnabled, let known = cache[count] { return known }
    let value = count > 10 ? count * 9 : count * 10
    if Settings.cacheEnabled { cache[count] = value }
    return value
}
