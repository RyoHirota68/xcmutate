import XCTest
@testable import SampleApp

/// 7.1 ネストした位置。XCTest で検出する。
@MainActor
final class NestedTests: XCTestCase {
    func testN1CompareCode() {
        XCTAssertEqual(Nested.compareCode(2, 1), 1)
        XCTAssertEqual(Nested.compareCode(2, 2), 0)
    }

    func testN2OuterAndInnerClosure() {
        XCTAssertEqual(Nested.filterAbove(1, [1, 2, 3], limit: 2), [3])
        XCTAssertEqual(Nested.filterAbove(0, [5], limit: 0), [])
    }

    func testN3Closures() {
        // 同じ優先度の要素の順序が保たれる（sorted は安定）。`<=` にすると入れ替わる。
        XCTAssertEqual(Nested.byPriority([("a", 1), ("b", 0), ("c", 1)]), ["b", "a", "c"])
        XCTAssertEqual(Nested.removing([1, 2, 1], 1), [2])
        XCTAssertTrue(Nested.allNonNegative([0, 1]))
        XCTAssertFalse(Nested.allNonNegative([-1]))
        XCTAssertEqual(Nested.flags([1, 2]), [false, true])
    }

    func testN4LoopGuardAndOuterComparison() {
        XCTAssertEqual(Nested.countNonNegative([0, -1, 2], cap: 10), 2)
        XCTAssertEqual(Nested.countNonNegative([1, 2], cap: 2), 2)
        XCTAssertEqual(Nested.countNonNegative([1, 2, 3], cap: 2), -1)
    }

    func testN5NestedLoops() {
        XCTAssertEqual(Nested.pairsBelow([2, 3], [1, 2, 3], threshold: 2), 2)
    }

    func testN6WhileAndRepeat() {
        XCTAssertEqual(Nested.triangular(3), 6)
        XCTAssertEqual(Nested.countdown(from: 3), [3, 2, 1])
    }

    func testN7OptionalBindingConditions() {
        XCTAssertEqual(Nested.withinTolerance([5], total: 7, tol: 2), 1)
        XCTAssertEqual(Nested.withinTolerance([4], total: 7, tol: 2), 0)
        XCTAssertEqual(Nested.atLeastFour(3), 0)
        XCTAssertEqual(Nested.atLeastFour(4), 4)
    }

    func testN8ImmediatelyInvokedClosure() {
        XCTAssertEqual(Nested.attempts([1, 2, 3, 4]), 4)
        XCTAssertEqual(Nested.attempts([1]), 0)
    }

    func testN9ForEach() {
        XCTAssertEqual(Nested.countPositive([0, 1, 2]), 2)
    }

    func testN10WhereClauses() {
        XCTAssertEqual(Nested.countPositiveWhere([0, 1, 2]), 2)
        XCTAssertEqual(Nested.sign(0), "zero")
        XCTAssertEqual(Nested.sign(1), "positive")
        XCTAssertEqual(Nested.sign(-1), "negative")
    }

    func testN11Defer() {
        XCTAssertEqual(Nested.drain(0), ["run"])
        XCTAssertEqual(Nested.drain(1), ["run", "cleanup"])
    }

    func testN12LabeledLoop() {
        XCTAssertEqual(Nested.rowsWithinLimit([[1, 2], [3]], limit: 2), 1)
    }

    func testN13TrailingClosureOnLibraryCall() {
        let done = expectation(description: "completion")
        nonisolated(unsafe) var result: Bool?
        Nested.asyncCompare(2, 2) { value in
            result = value
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(result, false)
    }
}
