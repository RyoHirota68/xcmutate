import Foundation
@testable import MutatorRunner
import Testing

@Suite("テストの自動絞り込み・受け入れ・二分探索")
struct SelectionAndAcceptanceTests {
    @Test func findsTestsByFileAndTypeName() {
        let tests: [(path: String, source: String)] = [
            ("UnitTests/Common/LoginUrlValidatorTests.swift", "import XCTest\nfinal class LoginUrlValidatorTests: XCTestCase {}\n"),
            ("UnitTests/Inspection/Checkers.swift", "@Suite(\"x\") struct ItemVariantCheckerTests {}\n@MainActor final class OtherTests: XCTestCase {}\n"),
            ("UnitTests/UIViewLayoutTests.swift", "struct UIViewLayoutTests {}\n"),
            ("UnitTests/Unrelated.swift", "final class CartTests: XCTestCase {}\n"),
        ]
        let matches = TestSelector.matches(
            sourceFiles: ["Legacy/Common/Utility/LoginUrlValidator.swift", "App/ItemVariantChecker.swift", "App/UIView+Layout.swift", "App/NoTests.swift"],
            testFiles: tests)
        #expect(matches.map(\.typeName) == ["ItemVariantCheckerTests", "UIViewLayoutTests", "LoginUrlValidatorTests"])
        #expect(!matches.contains { $0.typeName == "OtherTests" || $0.typeName == "CartTests" })
    }

    @Test func testPathsAndTypeNames() {
        #expect(TestSelector.isTestPath("UnitTests/Foo.swift"))
        #expect(TestSelector.isTestPath("App/FooTests.swift"))
        #expect(!TestSelector.isTestPath("App/Foo.swift"))
        let source = """
        @testable import App
        @MainActor
        final class FooTests: XCTestCase {}
        @Suite("Foo") struct FooSpec {}
        struct Helper {}
        private enum FooTestData {}
        """
        #expect(TestSelector.testTypeNames(in: source) == ["FooTests", "FooSpec"])
    }

    @Test func identifiersUseTargetFromPathOrSingleUnitTarget() {
        let match = TestSelector.Match(sourceFile: "A.swift", testFile: "UnitTests/ATests.swift", typeName: "ATests")
        let targets = [TestSelector.TestTarget(name: "AppTests", isUITest: false), TestSelector.TestTarget(name: "AppUITests", isUITest: true)]
        #expect(TestSelector.identifiers(for: [match], targets: targets) == ["AppTests/ATests"])
        let byPath = TestSelector.Match(sourceFile: "A.swift", testFile: "SampleAppTests/ATests.swift", typeName: "ATests")
        let two = [TestSelector.TestTarget(name: "SampleAppTests", isUITest: false), TestSelector.TestTarget(name: "KitTests", isUITest: false)]
        #expect(TestSelector.identifiers(for: [byPath], targets: two) == ["SampleAppTests/ATests"])
        #expect(TestSelector.identifiers(for: [match], targets: two) == nil)
        #expect(TestSelector.identifiers(for: [], targets: targets) == nil)
    }

    @Test func bisectorFindsACulprit() {
        // 3 と 7 が単独でコンパイルを壊す。base（0, 1）は通る
        let broken: Set<Int> = [3, 7]
        var builds = 0
        let culprit = CompileBisector.findCulprit(base: [0, 1], suspects: Array(2...9)) { set in
            builds += 1
            return broken.isDisjoint(with: set)
        }
        #expect(culprit == 3)
        #expect(builds <= 3)
        // 2つのミュータントが揃ったときだけ壊れる場合も、base ∪ {c} が壊れる c を返す
        let pair = CompileBisector.findCulprit(base: [], suspects: Array(0..<8)) { set in !(set.contains(2) && set.contains(5)) }
        #expect(pair == 5)
    }

    @Test func acceptedFileRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("accepted-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try AcceptedFile.load(url).accepted.isEmpty)
        let file = AcceptedFile(accepted: [.init(key: "A.swift::f()::boundary::0011", reason: "equivalent", location: "A.swift:1:2 > -> >=", acceptedAt: "2026-11-20T00:00:00Z")])
        try file.save(url)
        let loaded = try AcceptedFile.load(url)
        #expect(loaded.keys == ["A.swift::f()::boundary::0011"])
        #expect(loaded.accepted.first?.reason == "equivalent")
    }
}
