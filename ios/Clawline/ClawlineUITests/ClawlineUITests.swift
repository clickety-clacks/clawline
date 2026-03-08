//
//  ClawlineUITests.swift
//  ClawlineUITests
//
//  Created by Mike Manzano on 1/7/26.
//

import XCTest

final class ClawlineUITests: XCTestCase {
    private let keyboardStateIdentifier = "keyboard-dictation-state"
    private let composeFocusTargetIdentifier = "compose-focus-target"
    private let dictationMicIdentifier = "dictation-mic-button"
    private let startDictationIdentifier = "ui-test-start-dictation"
    private let stopDictationIdentifier = "ui-test-stop-dictation"
    private let forceKeyboardDismissIdentifier = "ui-test-force-keyboard-dismiss"
    private let dismissHitboxIdentifier = "ui-test-dismiss-hitbox"

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testExample() throws {
        // UI tests must launch the application that they test.
        let app = XCUIApplication()
        app.launch()

        // Use XCTAssert and related functions to verify your tests produce the correct results.
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }

    @MainActor
    func testScrollButtonDragMovesAndPersistsDetent() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "-auth.token", "debug-token",
            "-auth.userId", "debug-user",
            "-auth.isAdmin", "YES",
            "-provider.baseURL", "ws://127.0.0.1:8080",
            "--debug-force-scroll-button",
        ]
        app.launch()

        let button = app.buttons["scroll_to_bottom_button"]
        XCTAssertTrue(button.waitForExistence(timeout: 6), "Expected debug-forced scroll button to exist")
        XCTAssertTrue(button.isHittable, "Expected debug-forced scroll button to be hittable")

        let startFrame = button.frame
        let appMidX = app.frame.midX
        let primaryDragDeltaX: CGFloat = startFrame.midX < appMidX ? 220 : -220
        let start = button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = start.withOffset(CGVector(dx: primaryDragDeltaX, dy: 0))

        start.press(forDuration: 0.15, thenDragTo: end)
        sleep(1) // allow spring settle to complete before asserting frame.

        var draggedFrame = button.frame
        if abs(draggedFrame.midX - startFrame.midX) <= 24 {
            // Retry opposite direction if the first drag clamped near an edge.
            let retryStart = button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            let retryEnd = retryStart.withOffset(CGVector(dx: -primaryDragDeltaX, dy: 0))
            retryStart.press(forDuration: 0.15, thenDragTo: retryEnd)
            sleep(1)
            draggedFrame = button.frame
        }
        let draggedDelta = draggedFrame.midX - startFrame.midX
        XCTAssertGreaterThan(
            abs(draggedDelta),
            24,
            "Scroll button should move horizontally after drag gesture"
        )
        let movedRight = draggedDelta > 0

        app.terminate()
        app.launch()
        XCTAssertTrue(button.waitForExistence(timeout: 6))
        sleep(1)
        let relaunchedFrame = button.frame
        if movedRight {
            XCTAssertGreaterThan(
                relaunchedFrame.midX,
                startFrame.midX + 24,
                "Detent should persist across relaunch"
            )
        } else {
            XCTAssertLessThan(
                relaunchedFrame.midX,
                startFrame.midX - 24,
                "Detent should persist across relaunch"
            )
        }
    }

    @MainActor
    func testStartingDictationDoesNotCloseKeyboard() throws {
        let app = makeKeyboardDictationApp()
        app.launch()

        showKeyboardForDismissCheck(in: app)
        swipeUpOnComposeInputToStartDictation(in: app)
        waitForKeyboardState(in: app, focused: true, keyboardVisible: true, dictating: true)
    }

    @MainActor
    func testWhileDictatingTappingTextInputRefocusesAndShowsKeyboard() throws {
        let app = makeKeyboardDictationApp()
        app.launch()

        showKeyboardForDismissCheck(in: app)
        swipeUpOnComposeInputToStartDictation(in: app)
        waitForKeyboardState(in: app, focused: true, keyboardVisible: true, dictating: true)
        tapControl(named: forceKeyboardDismissIdentifier, in: app)
        waitForKeyboardState(in: app, focused: false, keyboardVisible: false, dictating: true)
        tapComposeInput(in: app)
        waitForKeyboardState(in: app, focused: true, keyboardVisible: true, dictating: true)
    }

    @MainActor
    func testStoppingDictationRestoresNormalKeyboardDismissal() throws {
        let app = makeKeyboardDictationApp()
        app.launch()

        showKeyboardForDismissCheck(in: app)
        swipeUpOnComposeInputToStartDictation(in: app)
        waitForKeyboardState(in: app, focused: true, keyboardVisible: true, dictating: true)

        swipeDownOnMessageList(in: app)
        waitForKeyboardState(in: app, focused: true, keyboardVisible: true, dictating: true)

        tapControl(named: stopDictationIdentifier, in: app)
        waitForKeyboardState(in: app, focused: true, keyboardVisible: true, dictating: false)

        swipeDownOnMessageList(in: app)
        waitForKeyboardState(in: app, focused: false, keyboardVisible: false, dictating: false)
    }

    @MainActor
    private func makeKeyboardDictationApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "-auth.token", "debug-token",
            "-auth.userId", "debug-user",
            "-auth.isAdmin", "YES",
            "-provider.baseURL", "ws://127.0.0.1:8080",
            "-soniox.apiKey", "ui-test-soniox-key",
            "-soniox.apiKeyStatus", "validated",
            "--ui-test-keyboard-dictation",
        ]
        return app
    }

    @MainActor
    private func waitForKeyboardState(
        in app: XCUIApplication,
        focused: Bool,
        keyboardVisible: Bool,
        dictating: Bool
    ) {
        let state = app.staticTexts[keyboardStateIdentifier]
        XCTAssertTrue(state.waitForExistence(timeout: 6), "Expected keyboard/dictation state probe")
        let expected = "focused=\(focused ? 1 : 0);keyboard=\(keyboardVisible ? 1 : 0);dictating=\(dictating ? 1 : 0)"
        let predicate = NSPredicate(format: "label == %@", expected)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: state)
        let result = XCTWaiter.wait(for: [expectation], timeout: 6)
        XCTAssertEqual(result, .completed, "Expected state \(expected), got \(state.label)")
    }

    @MainActor
    private func showKeyboardForDismissCheck(in app: XCUIApplication) {
        for _ in 0..<3 {
            tapComposeInput(in: app)
            if keyboardStateMatches(in: app, focused: true, keyboardVisible: true, dictating: false, timeout: 1.5) {
                return
            }
        }
        let currentState = app.staticTexts[keyboardStateIdentifier].label
        XCTFail("Expected composer tap to show keyboard before dismiss check; current state: \(currentState)")
    }

    @MainActor
    private func tapComposeInput(in app: XCUIApplication) {
        let textView = app.textViews["compose-text-view"]
        if textView.waitForExistence(timeout: 2), textView.isHittable {
            textView.tap()
            return
        }

        let editor = app.buttons[composeFocusTargetIdentifier]
        XCTAssertTrue(editor.waitForExistence(timeout: 6), "Expected compose input target to exist")
        editor.tap()
    }

    @MainActor
    private func tapControl(named identifier: String, in app: XCUIApplication) {
        let button = app.buttons[identifier]
        XCTAssertTrue(button.waitForExistence(timeout: 6), "Expected control \(identifier) to exist")
        if button.isHittable {
            button.tap()
        } else {
            button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
    }

    @MainActor
    private func swipeUpOnComposeInputToStartDictation(in app: XCUIApplication) {
        let composeInput = composeInputElement(in: app)
        let start = composeInput.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
        let end = start.withOffset(CGVector(dx: 0, dy: -140))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    @MainActor
    private func swipeDownOnMessageList(in app: XCUIApplication) {
        let messageList = app.collectionViews.element(boundBy: 0)
        XCTAssertTrue(messageList.waitForExistence(timeout: 6), "Expected message list to exist")
        let start = messageList.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
        let end = start.withOffset(CGVector(dx: 0, dy: 180))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    @MainActor
    private func composeInputElement(in app: XCUIApplication) -> XCUIElement {
        let textView = app.textViews["compose-text-view"]
        if textView.waitForExistence(timeout: 2) {
            return textView
        }

        let editor = app.buttons[composeFocusTargetIdentifier]
        XCTAssertTrue(editor.waitForExistence(timeout: 6), "Expected compose input target to exist")
        return editor
    }

    @MainActor
    private func waitForKeyboardAndDictationState(
        in app: XCUIApplication,
        keyboardVisible: Bool,
        dictating: Bool
    ) {
        let state = app.staticTexts[keyboardStateIdentifier]
        XCTAssertTrue(state.waitForExistence(timeout: 6), "Expected keyboard/dictation state probe")
        let expectedKeyboard = keyboardVisible ? "keyboard=1" : "keyboard=0"
        let expectedDictating = dictating ? "dictating=1" : "dictating=0"
        let predicate = NSPredicate { evaluated, _ in
            guard let element = evaluated as? XCUIElement else { return false }
            let label = element.label
            return label.contains(expectedKeyboard) && label.contains(expectedDictating)
        }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: state)
        let result = XCTWaiter.wait(for: [expectation], timeout: 6)
        XCTAssertEqual(result, .completed, "Expected state containing \(expectedKeyboard) and \(expectedDictating), got \(state.label)")
    }

    @MainActor
    private func keyboardStateMatches(
        in app: XCUIApplication,
        focused: Bool,
        keyboardVisible: Bool,
        dictating: Bool,
        timeout: TimeInterval
    ) -> Bool {
        let state = app.staticTexts[keyboardStateIdentifier]
        guard state.waitForExistence(timeout: timeout) else { return false }
        let expected = "focused=\(focused ? 1 : 0);keyboard=\(keyboardVisible ? 1 : 0);dictating=\(dictating ? 1 : 0)"
        let predicate = NSPredicate(format: "label == %@", expected)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: state)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }
}
