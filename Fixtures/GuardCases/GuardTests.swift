import Testing
import XCTest
@testable import SampleApp

/// Runs before the other guard suites in a run of all tests (XCTest runs classes in alphabetical order) and leaves
/// state for them: `ready` for GuardBPriceTests, the custom threshold for GuardCThresholdTests.
@MainActor
final class GuardASetupTests: XCTestCase {
    func testPrepare() {
        GuardState.shared.ready = true
        GuardState.shared.custom = 100
        XCTAssertTrue(GuardState.shared.ready)
    }
}

/// Passes in a run of all tests and fails by itself: it needs what GuardASetupTests left.
@MainActor
final class GuardBPriceTests: XCTestCase {
    func testExpensive() {
        XCTAssertTrue(GuardState.shared.ready, "needs GuardASetupTests to have run")
        XCTAssertTrue(Guards.isExpensive(500))
        XCTAssertTrue(Guards.isCheap(1))
    }

    func testNotExpensive() {
        XCTAssertTrue(GuardState.shared.ready, "needs GuardASetupTests to have run")
        XCTAssertFalse(Guards.isExpensive(5))
        XCTAssertFalse(Guards.isCheap(50))
    }
}

/// Passes by itself and after GuardASetupTests. With a mutant in `threshold()` it fails by itself and passes after
/// GuardASetupTests.
@MainActor
final class GuardCThresholdTests: XCTestCase {
    func testOver() { XCTAssertTrue(Guards.isOver(500)) }
    func testNotOver() { XCTAssertFalse(Guards.isOver(5)) }
}

/// Two tests reach each function of the crash row and the loop.
@MainActor
final class GuardDPickTests: XCTestCase {
    func testInside() {
        XCTAssertEqual(Guards.pickA(1), 20)
        XCTAssertEqual(Guards.pickB(1), 20)
        XCTAssertEqual(Guards.pickC(1), 20)
        XCTAssertEqual(Guards.drain(3), 3)
    }

    func testOutside() {
        XCTAssertEqual(Guards.pickA(3), 10)
        XCTAssertEqual(Guards.pickB(3), 20)
        XCTAssertEqual(Guards.pickC(3), 30)
        XCTAssertEqual(Guards.drain(4), 6)
    }
}

/// The function that the app also calls when it starts.
@MainActor
final class GuardELaunchTests: XCTestCase {
    func testPositive() { XCTAssertEqual(Guards.atLaunch(2), 2) }
    func testZero() { XCTAssertEqual(Guards.atLaunch(0), 1) }
}

/// Ends the test process once, when asked, whatever mutant is on: the shape of a test that ends its process once in
/// a while. scripts/make-guard-fixture.sh puts the path of a counter file here; the
/// file does not exist unless scripts/verify-fixture-guards.sh is run in the mode `end-once`, which writes a number
/// into it. Every run of this test lowers the number, and the run that brings it to zero ends the process.
final class GuardZEndOnceTests: XCTestCase {
    static let counter = "__GUARD_COUNTER__"

    func testEndsTheProcessWhenAsked() {
        guard let text = try? String(contentsOfFile: Self.counter, encoding: .utf8),
              let left = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
        try? String(left - 1).write(toFile: Self.counter, atomically: true, encoding: .utf8)
        if left == 1 { exit(0) }
    }
}

/// A Swift Testing suite whose tests have display names.
@MainActor
struct GuardNamedTests {
    @Test("picks inside the table") func inside() { #expect(Guards.pickNamed(1) == 20) }
    @Test("picks the first entry outside the table") func outside() { #expect(Guards.pickNamed(3) == 10) }
}
