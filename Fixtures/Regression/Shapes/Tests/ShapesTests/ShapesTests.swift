import XCTest
@testable import Shapes

final class ShapesTests: XCTestCase {
    func testClassify() {
        XCTAssertEqual(classify(-1), "neg")
        XCTAssertEqual(classify(0), "zero")
        XCTAssertEqual(classify(1), "pos")
        XCTAssertEqual(classify(5), "pos")
    }

    func testTitles() {
        XCTAssertEqual(Tab.home.title, "Home")
        XCTAssertEqual(Tab.settings.title, "Settings")
        XCTAssertEqual(Tab.other.title, "Other")
        XCTAssertEqual(Tab.home.subtitle, "H")
        XCTAssertEqual(Tab.other.subtitle, "X")
    }

    func testShape() {
        XCTAssertEqual(shape(round: true).sides, 0)
        XCTAssertEqual(shape(round: false).sides, 4)
    }

    func testTemplate() {
        XCTAssertTrue(testFileTemplate(module: "App", cases: 2).hasPrefix("// 2 cases\nimport XCTest"))
        XCTAssertTrue(testFileTemplate(module: "App", cases: 0).hasPrefix("// empty"))
    }

    func testScale() {
        XCTAssertEqual(screenScale(7), 7)
    }

    func testInRange() {
        XCTAssertTrue(inRange(2, 8))
        XCTAssertFalse(inRange(1, 8))
        XCTAssertFalse(inRange(2, 9))
    }
}
