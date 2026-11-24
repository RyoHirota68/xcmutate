import Testing
@testable import SampleApp

/// ユニットテストのターゲットの2つ目（スキーム SampleAppUnits）。こちらは Swift Testing。
@MainActor
@Suite struct UnitBTests {
    @Test func u2Clamp() {
        #expect(UnitCases.clamp(-1) == 0)
        #expect(UnitCases.clamp(3) == 3)
    }

    @Test func u4Label() {
        #expect(!UnitCases.label(1).isEmpty)
    }

    @Test func u6Total() {
        #expect(UnitCases.total([1, 2, 3], count: 3) == 6)
        #expect(UnitCases.total([1, 2, 3], count: 2) == 3)
        // 個数が配列より多いとき（境界を <= にしたミュータントは範囲外の添字でクラッシュする）
        #expect(UnitCases.total([1, 2, 3], count: 4) == 6)
    }
}
