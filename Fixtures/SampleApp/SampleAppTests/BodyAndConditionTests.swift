import Testing
@testable import SampleApp

/// 7.11 本体と条件の演算子。意図的なテストの穴（EB2・CA2・SC1-untested・TN2・CC2）を残す。
@MainActor
@Suite struct BodyAndConditionTests {
    @Test func eb1Activate() {
        let counter = BodyCounter()
        counter.activate()
        #expect(counter.isActive)
    }

    @Test func eb2RenameIsOnlyCalled() {
        BodyCounter().rename("x")
    }

    @Test func eb3And4() {
        let counter = BodyCounter()
        counter.activateIfNeeded()
        #expect(counter.isActive)
        let other = BodyCounter()
        other.activateTwice()
        #expect(other.isActive)
    }

    @Test func caCompoundAssignments() {
        let counter = BodyCounter()
        counter.add(3)
        #expect(counter.count == 3)
        counter.discount(0)
        #expect(counter.count == 3)
        counter.scale(2)
        #expect(counter.count == 6)
        counter.append("x")
        #expect(counter.label == "-x")
    }

    @Test func sc1Weight() {
        #expect(BodyAndCondition.weight(.small) == 1)
        #expect(BodyAndCondition.weight(.large) == 5)
        #expect(BodyAndCondition.weight(.unknown) == 0)
    }

    @Test func sc2Bucket() {
        #expect(BodyAndCondition.bucket(200, .small) == "big")
        #expect(BodyAndCondition.bucket(0, .small) == "zero")
        #expect(BodyAndCondition.bucket(1, .small) == "s")
        #expect(BodyAndCondition.bucket(1, .huge) == "other")
    }

    @Test func tnTryOptional() {
        #expect(BodyAndCondition.parsedOrZero("12") == 12)
        #expect(BodyAndCondition.parsedOrZero("x") == 0)
        #expect(BodyAndCondition.parsedOrMinusOne("x") == -1)
        #expect(BodyAndCondition.warmUp("1"))
        #expect(BodyAndCondition.parsed("7") == 7)
        #expect(BodyAndCondition.parsed("x") == nil)
    }

    @Test func ccConditions() {
        #expect(BodyAndCondition.half(4) == 2)
        #expect(BodyAndCondition.half(-4) == 0)
        #expect(BodyAndCondition.doubled(0) == 0)
        #expect(BodyAndCondition.doubled(2) == 4)
        #expect(BodyAndCondition.clampNegative(-3, true) == 0)
        #expect(BodyAndCondition.clampNegative(-3, false) == -3)
        #expect(BodyAndCondition.clampNegative(3, true) == 3)
    }

    @Test func dcDisableComments() {
        #expect(BodyAndCondition.isAdult(18, true))
        #expect(!BodyAndCondition.isAdult(17, true))
        #expect(!BodyAndCondition.isAdult(18, false))
        #expect(BodyAndCondition.isSenior(65))
        #expect(!BodyAndCondition.isSenior(64))
        #expect(BodyAndCondition.inRange(3))
        #expect(!BodyAndCondition.inRange(0))
        #expect(!BodyAndCondition.inRange(10))
        #expect(!BodyAndCondition.inRange(5))
    }
}
