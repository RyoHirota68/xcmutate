import LegacyKit
import Testing

/// L1・L2: Swift 5 モード・InternalImportsByDefault 無しのモジュール。
@Suite struct LegacyKitTests {
    @Test func padded() {
        #expect(LegacyFormatting.padded(9) == "09")
        #expect(LegacyFormatting.padded(10) == "10")
    }

    @Test func trimmed() {
        #expect(LegacyFormatting.trimmedName(" a ") == "a")
    }

    @Test func even() {
        #expect(LegacyPlain.isEven(2))
        #expect(!LegacyPlain.isEven(3))
    }
}
