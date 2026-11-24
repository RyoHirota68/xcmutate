// Cases for scripts/verify-fixture-guards.sh. This file is not part of Fixtures/SampleApp: the script copies the
// fixture, adds this file to the app and GuardTests.swift to the unit tests, and runs only this file's mutants.
//
// The order matters. The functions that crash the test host come first: several crashes in a row make the tool
// pause shared processes, and the mutants after them are then run alone, which is the path that the cases below
// are about (docs/verification.md).
enum Guards {
    static let table = [10, 20, 30]

    // Crash row: an index out of range. Each function is reached by two tests.
    static func pickA(_ i: Int) -> Int { table[i < 3 ? i : 0] }
    static func pickB(_ i: Int) -> Int { table[i < 3 ? i : 1] }
    static func pickC(_ i: Int) -> Int { table[i < 3 ? i : 2] }

    // Suites that need another suite: GuardBPriceTests asserts that GuardASetupTests has run. The boundaries are
    // not tested: both mutants survive every way of running.
    static func isExpensive(_ price: Int) -> Bool { price >= 100 }
    static func isCheap(_ price: Int) -> Bool { price < 10 }

    // State that hides a mutant: GuardASetupTests sets the custom threshold to the default's value, so in a run of
    // all tests the default is never used and the mutants of threshold() survive. GuardCThresholdTests by itself
    // has no custom threshold: with a mutant the threshold is wrong and it fails.
    static func threshold() -> Int { GuardState.shared.custom > 0 ? GuardState.shared.custom : 100 }
    static func isOver(_ value: Int) -> Bool { value >= threshold() }

    // One test that does not end: without the removal of the first element the loop goes on for ever.
    static func drain(_ n: Int) -> Int {
        var queue = Array(0..<n)
        var total = 0
        while !queue.isEmpty {
            total = total + queue[0]
            queue.removeFirst()
        }
        return total
    }

    // Reached while the app starts (scripts/make-guard-fixture.sh calls it from the app's initializer), before any
    // test: with --select-tests reach the test process of the baseline then writes the lines of its tests into the
    // trace file from the start, and the log of xcodebuild has none. The limits inside a run (until the first
    // test, for one test) must be in use all the same; where code that starts with the app
    // had mutants, they were not.
    static func atLaunch(_ n: Int) -> Int { n > 0 ? n : 1 }

    // A crash in a Swift Testing test that has a display name. The log of xcodebuild names such a test by the
    // display name, which is not an identifier: a Crash that is stopped at the first crash says the name in its
    // detail and does not list it among the tests (it used to be listed).
    static func pickNamed(_ i: Int) -> Int { table[i < 3 ? i : 0] }
}

final class GuardState {
    static let shared = GuardState()
    var ready = false
    var custom = 0
}
