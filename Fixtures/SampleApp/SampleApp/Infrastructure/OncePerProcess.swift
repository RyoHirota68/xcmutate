/// OP1: code that is evaluated once per process (the initial value of a `static let`). The test that happens to
/// touch `OnceConfig.limit` first evaluates the switch; the test that can detect the mutant is in another suite and
/// only reads the stored value. `--select-tests reach` must not narrow such a mutant to the suite of the first test.
nonisolated enum OnceConfig {
    static let limit = defaultLimit(wide: true)  // @case OP1-init

    static func defaultLimit(wide: Bool) -> Int {
        return wide ? 10 : 20  // @case OP1
    }
}

nonisolated struct OnceValidator {
    func isValid(_ n: Int) -> Bool {
        return n < OnceConfig.limit  // @case OP1-use
    }
}
