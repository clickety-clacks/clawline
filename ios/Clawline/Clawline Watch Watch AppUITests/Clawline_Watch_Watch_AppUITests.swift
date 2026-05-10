import XCTest

final class Clawline_Watch_Watch_AppUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testCaptureSolidRingStatesAndHistoryScroll() throws {
        let scenario = Self.compileTimeScenario
        captureScenario(named: scenario.name, expectedRouteLabel: scenario.expectedRouteLabel, screenshotName: scenario.screenshotName) { app in
            guard scenario.name == "direct" else { return }
            self.saveScreenshot(app: app, name: "watch-direct-history-initial")
            app.swipeDown()
            self.saveScreenshot(app: app, name: "watch-direct-history-scrolled-up")
            app.swipeUp()
            self.saveScreenshot(app: app, name: "watch-direct-history-scrolled-down")
        }
    }

    private static var compileTimeScenario: (name: String, expectedRouteLabel: String, screenshotName: String) {
#if WATCH_UI_SCENARIO_RELAY
        return ("relay", "Via iPhone", "watch-relay-solid")
#elseif WATCH_UI_SCENARIO_RECONNECTING
        return ("reconnecting", "Reconnecting…", "watch-reconnecting-solid")
#elseif WATCH_UI_SCENARIO_DISCONNECTED
        return ("disconnected", "No Connection", "watch-disconnected-solid")
#else
        return ("direct", "Direct", "watch-direct-solid")
#endif
    }

    @MainActor
    private func captureScenario(named scenario: String, expectedRouteLabel: String, screenshotName: String, afterLaunch: ((XCUIApplication) -> Void)? = nil) {
        let app = XCUIApplication()
        app.launchArguments += ["-WATCH_UI_TEST_SCENARIO", scenario]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        let routeLabel = app.staticTexts[expectedRouteLabel]
        XCTAssertTrue(routeLabel.waitForExistence(timeout: 10), "Expected route label \(expectedRouteLabel) for scenario \(scenario)")
        sleep(1)
        afterLaunch?(app)
        saveScreenshot(app: app, name: screenshotName)
        app.terminate()
    }

    @MainActor
    private func saveScreenshot(app: XCUIApplication, name: String) {
        let screenshot = app.otherElements["watch-main-root"].exists ? app.otherElements["watch-main-root"].screenshot() : app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
