import XCTest
@testable import SampleApp

/// 7.6 副作用の文の削除。
@MainActor
final class SideEffectTests: XCTestCase {
    func testR1VoidCall() {
        let cache = Cache()
        SideEffects.remember(cache, "k", 1)
        XCTAssertEqual(cache.stored, ["k": 1])
    }

    func testR2DiscardedResults() {
        let repo = Repo()
        SideEffects.persist(repo, 1)
        SideEffects.persistQuietly(repo, 2)
        XCTAssertEqual(repo.saved, [1, 2])
    }

    func testR4NeverReturningCalls() {
        SideEffects.ensure(true)
    }

    func testR5GuardElse() {
        XCTAssertEqual(SideEffects.firstPositive([0, 2]), 2)
        XCTAssertNil(SideEffects.firstPositive([0]))
    }

    func testR6Initializers() {
        XCTAssertEqual(Derived(flag: 0).id, 1)
    }

    func testR7Deinit() {
        let counter = DeinitCounter()
        do {
            let tracker = Tracker(counter: counter)
            tracker.active = 1
        }
        XCTAssertEqual(counter.value, 1)
    }

    func testR8Lock() {
        let counter = SafeCounter()
        counter.increment()
        XCTAssertEqual(counter.current, 1)
    }

    func testR9AridCalls() {
        XCTAssertEqual(SideEffects.logged(2), 2)
        SideEffects.relayout(UIView())
    }

    func testR10Loop() {
        XCTAssertEqual(SideEffects.sumBelow(3), 3)
    }

    func testR11Queue() {
        XCTAssertEqual(SideEffects.drainQueue(3), 3)
    }
}
