import Testing
import XCTest
@testable import SampleApp

/// 7.8 X1: XCTest だけで検出する。
@MainActor
final class XCTestOnlyTests: XCTestCase {
    func testX1XCTestOnly() {
        XCTAssertFalse(TestKinds.xcTestOnly(1))
        XCTAssertTrue(TestKinds.xcTestOnly(2))
    }

    /// X3: ミュータントでは範囲外アクセスでクラッシュする。
    func testX3Crash() {
        XCTAssertEqual(TestKinds.element([1, 2], 1), 2)
        XCTAssertEqual(TestKinds.element([1, 2], 2), -1)
    }

    /// X4: 既知の失敗を含むが、全体としては成功するテスト。
    func testX4ExpectFailure() {
        XCTExpectFailure("known issue") {
            XCTFail("this failure is expected")
        }
    }

    /// X5: ログに `fatal error` という文字列を出す成功テスト（#189）。
    func testX5FatalErrorStringInLog() {
        print("fatal error: this is just a log line from a passing test")
        XCTAssertTrue(true)
    }

    /// X7: ホットループ。
    func testX7HotLoop() {
        XCTAssertEqual(TestKinds.countMultiplesOfSeven(below: 1_000_000), 142_858)
    }

    /// X10: `==` だけを定義した型。
    func testX10CustomEquality() {
        XCTAssertTrue(Tokens.same(Token(raw: 1), Token(raw: 1)))
        XCTAssertFalse(Tokens.same(Token(raw: 1), Token(raw: 2)))
    }

    /// X8: ファイル名に `+` を含む・同名ファイル。
    func testX8FileNames() {
        let a = UIView(frame: .init(x: 0, y: 0, width: 10, height: 10))
        let b = UIView(frame: .init(x: 0, y: 0, width: 10, height: 10))
        XCTAssertFalse(a.isWider(than: b))
        b.frame.size.width = 5
        XCTAssertTrue(a.isWider(than: b))
        XCTAssertTrue(FeatureAValidator.isValid("abc"))
        XCTAssertFalse(FeatureAValidator.isValid("ab"))
        XCTAssertTrue(Declarations.featureBValid("abcde"))
        XCTAssertFalse(Declarations.featureBValid("abcdef"))
    }
}

/// 7.8 X1・X2: Swift Testing だけで検出する。
@MainActor
@Suite struct SwiftTestingOnlyTests {
    @Test func x1SwiftTestingOnly() {
        #expect(!TestKinds.swiftTestingOnly(1))
        #expect(TestKinds.swiftTestingOnly(0))
    }

    @Test(arguments: [0, 1, 2])
    func x2Parameterized(value: Int) {
        #expect(TestKinds.parameterized(value) == (value != 0))
    }

    /// X4: withKnownIssue を含む成功するテスト。
    @Test func x4KnownIssue() {
        withKnownIssue {
            Issue.record("this issue is known")
        }
    }
}

/// 7.12 X12・X13: 名前が `Test.swift` で終わる製品コードと、`exclude` の `!` で対象に戻したファイル。
@MainActor
@Suite struct FileSelectionTests {
    @Test func x12ABTestIsProductCode() {
        #expect(ABTest.bucket(for: 2) == "A")
        #expect(ABTest.bucket(for: 3) == "B")
    }

    @Test func x13KeptAndExcluded() {
        #expect(Kept.isPositive(1))
        #expect(!Kept.isPositive(0))
        #expect(Vendor.isSupported(3))
        #expect(GeneratedStrings.plural(1) == "item")
        #expect(TestHelpers.isSmall(1))
    }
}

/// OP1: the first test that touches `OnceConfig.limit` (XCTest runs classes in alphabetical order, so this one comes
/// before `OnceBUseTests`). It checks nothing that a mutant changes.
final class OnceATouchTests: XCTestCase {
    func testOP1TouchesTheValueFirst() {
        XCTAssertGreaterThan(OnceConfig.limit, 0)
    }
}

/// OP1: the test that detects a mutant in the initial value of `OnceConfig.limit`, without evaluating it.
final class OnceBUseTests: XCTestCase {
    func testOP1LimitIsTen() {
        XCTAssertTrue(OnceValidator().isValid(9))
        XCTAssertFalse(OnceValidator().isValid(10))
    }
}
