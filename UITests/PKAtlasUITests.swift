import XCTest

final class PKAtlasUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testNativeDashboardHasNoWebWrapper() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["native.add.dose"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts["本地计算"].exists)
        XCTAssertTrue(app.buttons["native.global.add.dose"].exists)
        XCTAssertFalse(app.webViews.firstMatch.exists,
                       "The native app must not ship a WKWebView as its primary UI")
        XCTAssertTrue(app.staticTexts["群体药代模型 · 不是个人血药实测，也不是用药建议"].exists)
    }

    func testRecordEditorIsNative() throws {
        let app = XCUIApplication()
        app.launch()
        let add = app.buttons["native.add.dose"]
        XCTAssertTrue(add.waitForExistence(timeout: 30))
        add.tap()
        XCTAssertTrue(app.textFields["native.dose.amount"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["native.dose.save"].exists)
        app.buttons["取消"].tap()
        XCTAssertTrue(add.exists)
    }

    func testNativeChartAndHistoryTabs() throws {
        let app = XCUIApplication()
        app.launch()
        let chart = app.buttons["曲线"]
        XCTAssertTrue(chart.waitForExistence(timeout: 30))
        chart.tap()
        XCTAssertTrue(app.staticTexts["24 小时模型曲线"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.webViews.firstMatch.exists)
        app.buttons["历史"].tap()
        XCTAssertTrue(app.navigationBars["历史记录"].waitForExistence(timeout: 10))
    }

    func testAppReleaseCheckHasAnonymousManualControl() throws {
        let app = XCUIApplication()
        app.launch()
        let settings = app.buttons["我的"]
        XCTAssertTrue(settings.waitForExistence(timeout: 30))
        settings.tap()
        let update = app.buttons["native.release.check"]
        for _ in 0..<6 where !update.exists {
            app.swipeUp()
        }
        XCTAssertTrue(update.waitForExistence(timeout: 15),
                      "Version checking must be available without signing in")
        let status = app.staticTexts["native.release.status"]
        XCTAssertTrue(status.exists)
        for _ in 0..<6 where !update.isHittable { app.swipeUp() }
        XCTAssertTrue(update.isHittable)
        update.tap()
        let checked = NSPredicate(format: "label CONTAINS %@", "签名验证通过")
        expectation(for: checked, evaluatedWith: status)
        waitForExpectations(timeout: 25)
        XCTAssertFalse(app.webViews.firstMatch.exists)
    }

    func testSiriAndLocalNotificationsAreNative() throws {
        let app = XCUIApplication()
        app.launch()
        let settings = app.buttons["我的"]
        XCTAssertTrue(settings.waitForExistence(timeout: 30))
        settings.tap()
        XCTAssertTrue(app.buttons["开启系统通知"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["同步未来 7 天本机提醒"].exists)
        XCTAssertTrue(app.buttons["native.auth.browser"].exists)
        // App Intents discovery is separately verified by native XCTest;
        // Form accessibility groups static labels differently across Duo poses.
        XCTAssertFalse(app.webViews.firstMatch.exists)
    }
}
