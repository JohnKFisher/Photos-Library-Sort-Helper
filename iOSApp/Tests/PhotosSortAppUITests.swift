import XCTest

@MainActor
final class PhotosSortAppUITests: XCTestCase {
    func testHomeDoesNotRequestPhotosAccessAtLaunch() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.staticTexts["Photos Sort Helper"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Continue Sorting"].exists)
        XCTAssertFalse(app.alerts.firstMatch.exists)
    }

    func testReviewModeCanChangeWithoutStartingPhotosWork() throws {
        let app = XCUIApplication()
        app.launch()

        let keepFirst = app.buttons["Keep-first"]
        XCTAssertTrue(keepFirst.waitForExistence(timeout: 5))
        keepFirst.tap()
        XCTAssertTrue(app.staticTexts["Unmarked photos stay provisional until you complete a group."].exists)
        XCTAssertFalse(app.alerts.firstMatch.exists)
    }
}
