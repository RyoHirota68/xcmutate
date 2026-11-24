import Testing
@testable import SampleApp

/// 7.5 SwiftUI・result builder・マクロ。View 自体のテストは書かない（S1・S2 は Survived になる）。
@MainActor
@Suite struct SwiftUICasesTests {
    @Test func s3ViewModelMethod() {
        let model = CounterModel()
        #expect(!model.canDecrement())
        model.count = 1
        #expect(model.canDecrement())
    }

    @Test func s4ObservablePropertyInitializer() {
        #expect(!CounterModel().isReady)
    }

    @Test func s5CustomResultBuilder() {
        #expect(SwiftUICases.tags(for: 10) == ["n=10", "big=false"])
        #expect(SwiftUICases.tags(for: 11) == ["n=11", "big=true"])
        #expect(SwiftUICases.tags(for: 0) == ["n=0", "big=false", "zero"])
    }

    @Test func s6Predicate() throws {
        #expect(try SwiftUICases.adults.evaluate(Person(age: 19)))
    }

    @Test func s8ExtractedFunction() {
        #expect(SwiftUICases.badgeText(count: 99) == "99")
        #expect(SwiftUICases.badgeText(count: 100) == "99+")
    }
}
