import XCTest

final class Clawline_Watch_Watch_AppUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testMicTapStartsVoiceOrShowsVisibleError() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-WATCH_UI_TEST_SCENARIO", "direct"]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

        let ringControls = app.descendants(matching: .any).matching(identifier: "watch-ring-control")
        XCTAssertEqual(ringControls.count, 1, "Expected exactly one exposed microphone ring control")
        let ringControl = ringControls.firstMatch
        XCTAssertTrue(ringControl.waitForExistence(timeout: 10), "Expected microphone ring control")
        saveScreenshot(app: app, name: "watch-mic-before-tap")

        ringControl.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        saveScreenshot(app: app, name: "watch-mic-after-tap-immediate")

        let listening = app.staticTexts["Listening..."]
        let visibleVoiceError = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@ OR label CONTAINS[c] %@ OR label CONTAINS[c] %@",
                        "Soniox",
                        "Microphone",
                        "Voice couldn't",
                        "Watch relay")
        ).firstMatch
        let enteredListening = listening.waitForExistence(timeout: 2)
        let surfacedVoiceError = visibleVoiceError.waitForExistence(timeout: 4)
        XCTAssertTrue(
            enteredListening || surfacedVoiceError,
            "Expected mic tap to enter listening or surface a Clawline voice error"
        )
        sleep(2)
        saveScreenshot(app: app, name: "watch-mic-after-tap-2s")
        app.terminate()
    }

    @MainActor
    func testCaptureSolidRingStatesAndHistoryScroll() throws {
        let scenario = Self.compileTimeScenario
        captureScenario(named: scenario.name, expectsRouteChip: scenario.expectsRouteChip, screenshotName: scenario.screenshotName) { app in
            guard scenario.name == "direct" else { return }
            self.saveScreenshot(app: app, name: "watch-direct-history-initial")
            app.swipeDown()
            self.saveScreenshot(app: app, name: "watch-direct-history-scrolled-up")
            app.swipeUp()
            self.saveScreenshot(app: app, name: "watch-direct-history-scrolled-down")
        }
    }

    private static var compileTimeScenario: (name: String, expectsRouteChip: Bool, screenshotName: String) {
#if WATCH_UI_SCENARIO_RELAY
        return ("relay", true, "watch-relay-solid")
#elseif WATCH_UI_SCENARIO_RECONNECTING
        return ("reconnecting", false, "watch-reconnecting-solid")
#elseif WATCH_UI_SCENARIO_DISCONNECTED
        return ("disconnected", false, "watch-disconnected-solid")
#else
        return ("direct", true, "watch-direct-solid")
#endif
    }

    @MainActor
    private func captureScenario(named scenario: String, expectsRouteChip: Bool, screenshotName: String, afterLaunch: ((XCUIApplication) -> Void)? = nil) {
        let app = XCUIApplication()
        app.launchArguments += ["-WATCH_UI_TEST_SCENARIO", scenario]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        let ringControl = app.descendants(matching: .any)["watch-ring-control"]
        XCTAssertTrue(ringControl.waitForExistence(timeout: 10), "Expected ring control for scenario \(scenario)")
        if expectsRouteChip {
            let channelTitle = app.staticTexts["Flynn"]
            XCTAssertTrue(channelTitle.waitForExistence(timeout: 10), "Expected channel row for scenario \(scenario)")
        }
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
