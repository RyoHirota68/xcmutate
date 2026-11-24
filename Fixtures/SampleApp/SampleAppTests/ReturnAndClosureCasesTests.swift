import Foundation
import Testing
@testable import SampleApp

/// 戻り値とクロージャの演算子。意図的なテストの穴（RC2 の中身・IR3・CS2-empty の等価）を残す。
@MainActor
@Suite struct ReturnAndClosureCasesTests {
    @Test func rc1Lookup() {
        #expect(ReturnAndClosure.lookup("", in: [:]) == .invalid("empty"))
        #expect(ReturnAndClosure.lookup("a", in: [:]) == .missing)
        #expect(ReturnAndClosure.lookup("a", in: ["a": 1]) == .found(1))
    }

    /// RC2: 「見つからない」ではないことしか確かめない。負の値のテストも無い
    @Test func rc2LookupLoose() {
        #expect(ReturnAndClosure.lookupLoose("a", in: ["a": 1]) != .missing)
    }

    @Test func ir1Doubled() {
        #expect(ReturnAndClosure.doubled([1, 2]) == [2, 4])
    }

    @Test func ir2FirstName() {
        #expect(ReturnAndClosure.firstName(["a", "b"]) == "a")
    }

    /// IR3: 呼ぶだけ
    @Test func ir3Label() {
        _ = ReturnAndClosure.label(1)
    }

    @Test func cs1Collect() {
        #expect(ReturnAndClosure.collect([1, 2]) == [1, 2])
    }

    @Test func cs2TakeWhilePositive() {
        #expect(ReturnAndClosure.takeWhilePositive([1, 2, -1, 3]) == [1, 2])
        #expect(ReturnAndClosure.takeWhilePositive([0, 5]) == [])
        #expect(ReturnAndClosure.takeWhilePositive([-1]) == [])
    }

    @Test func cs3Mapped() {
        #expect(ReturnAndClosure.mapped([1]) == [2])
    }

    @Test func cs4Drain() {
        #expect(ReturnAndClosure.drain([1, 2], lock: NSLock()) == 3)
    }
}
