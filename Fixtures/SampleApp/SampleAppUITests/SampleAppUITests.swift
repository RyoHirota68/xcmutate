import XCTest

/// X6: UI テストターゲット。ミュータントの実行に含めない（`TEST_RUNNER_` の環境変数は
/// UI テストが起動するアプリには届かないため）。ベースラインでは成功すること。
final class SampleAppUITests: XCTestCase {
    @MainActor
    func testLaunch() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
    }
}
