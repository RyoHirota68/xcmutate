import Testing
@testable import SampleApp

/// 7.9 戻り値と制御の流れの演算子。意図的なテストの穴（O1-unlinked・O2 の組み合わせ・O3-guard・O5-lowercased）を残す。
@MainActor
@Suite struct NewOperatorTests {
    @Test func o1VariantSetting() {
        #expect(NewOperators.variantSetting(masterId: 1, settings: [:]) == .unknown)
        #expect(NewOperators.variantSetting(masterId: 1, settings: [1: true]) == .hasVariant)
        #expect(NewOperators.variantSetting(masterId: 1, settings: [1: false]) == .noVariant)
    }

    @Test func o2Combine() {
        #expect(NewOperators.combine([.noVariant]) == .noVariant)
        #expect(NewOperators.combine([.unknown]) == .unknown)
        #expect(NewOperators.combine([.noVariant, .hasVariant]) == .hasVariant)
    }

    @Test func o2CombineTested() {
        #expect(NewOperators.combineTested([.noVariant]) == .noVariant)
        #expect(NewOperators.combineTested([.unknown]) == .unknown)
        #expect(NewOperators.combineTested([.noVariant, .hasVariant]) == .hasVariant)
        #expect(NewOperators.combineTested([.unknown, .hasVariant]) == .hasVariant)
    }

    @Test func o3Conditions() {
        #expect(NewOperators.connectedHost("a") == "a")
        #expect(NewOperators.connectedHost(nil) == nil)
        #expect(NewOperators.port(8080) == 8080)
        #expect(NewOperators.port(0) == nil)
        #expect(NewOperators.port(nil) == nil)
    }

    @Test func o4LoopControl() {
        #expect(NewOperators.countBeforeNegative([1, -1, 2]) == 1)
        #expect(NewOperators.countBeforeNegative([0, -1]) == 1)
    }

    @Test func o5Normalization() {
        #expect(NewOperators.matchesHost("a.com", connected: "a.com"))
        #expect(!NewOperators.matchesHost("a.com", connected: "b.com"))
        #expect(NewOperators.normalizedCode(" a ") == "a")
    }

    @Test func o6AridConfig() {
        #expect(NewOperators.track(3) == 3)
    }
}
