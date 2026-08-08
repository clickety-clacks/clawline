import XCTest

/// Behavior-level pin for the chat-picker rename focus lifecycle.
/// The core multi-keystroke test was independently derived by the reviewer and
/// discriminated the pre-fix baseline from the original fix commit.
final class StreamRenameFocusReviewUITests: XCTestCase {
    private static let fixtureStreamName = "Goal A fixture verification"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    private func launchFixtureApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["--debug-goalA-fixture-transcript"]
        app.launch()
        return app
    }

    private func filterField(in app: XCUIApplication) -> XCUIElement {
        app.textFields
            .matching(NSPredicate(format: "placeholderValue == %@", "Filter..."))
            .firstMatch
    }

    private func renameField(in app: XCUIApplication) -> XCUIElement {
        app.textFields
            .matching(NSPredicate(format: "placeholderValue == %@", "Stream name"))
            .firstMatch
    }

    private func hasKeyboardFocus(_ element: XCUIElement) -> Bool {
        (element.value(forKey: "hasKeyboardFocus") as? Bool) ?? false
    }

    private func waitForExistence(
        _ element: XCUIElement,
        expected: Bool,
        timeout: TimeInterval = 6
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in element.exists == expected },
            object: nil
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func sampleFilterFocusSteals(
        _ app: XCUIApplication,
        duration: TimeInterval,
        interval: TimeInterval = 0.1
    ) -> Int {
        let filter = filterField(in: app)
        var steals = 0
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline {
            if filter.exists, hasKeyboardFocus(filter) {
                steals += 1
            }
            Thread.sleep(forTimeInterval: interval)
        }
        return steals
    }

    @MainActor
    private func openPicker(_ app: XCUIApplication) {
        app.typeKey("/", modifierFlags: [])
    }

    @MainActor
    private func beginRename(in app: XCUIApplication) {
        let row = app.staticTexts[Self.fixtureStreamName].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Fixture stream row should be listed")
        row.press(forDuration: 1.2)
        let renameItem = app.buttons["Rename"].firstMatch
        XCTAssertTrue(renameItem.waitForExistence(timeout: 6), "Context menu should offer Rename")
        renameItem.tap()
    }

    private func assertPickerReadyAfterSubmit(_ app: XCUIApplication) {
        Thread.sleep(forTimeInterval: 3.0)
        let rename = renameField(in: app)
        let filter = filterField(in: app)
        XCTAssertTrue(rename.waitForExistence(timeout: 6), "Failed or empty submit should preserve the draft")
        XCTAssertFalse(hasKeyboardFocus(rename), "Submitted rename should release focus")
        XCTAssertTrue(hasKeyboardFocus(filter), "Filter should hold focus after submit")

        let addStream = app.buttons["Add stream"].firstMatch
        XCTAssertTrue(addStream.waitForExistence(timeout: 6))
        XCTAssertTrue(addStream.isEnabled, "Add stream should be enabled after inline editing finishes")

        let track = app.buttons["Track"].firstMatch
        if track.exists {
            XCTAssertTrue(track.isEnabled, "Track should be enabled after inline editing finishes")
        }

        app.typeText("zz")
        XCTAssertEqual(filter.value as? String, "zz", "Keystrokes after submit must reach the filter")
    }

    @MainActor
    func testPickerOpenAutoFocusesFilterField() throws {
        let app = launchFixtureApp()
        openPicker(app)

        let filter = filterField(in: app)
        XCTAssertTrue(filter.waitForExistence(timeout: 10), "Picker open should render the filter field")
        XCTAssertTrue(hasKeyboardFocus(filter), "Picker open should auto-focus the filter field")

        app.typeText("ab")
        XCTAssertEqual(filter.value as? String, "ab", "Keystrokes after open should land in the filter")
    }

    @MainActor
    func testRenameKeepsFocusAcrossMultipleKeystrokes() throws {
        let app = launchFixtureApp()
        openPicker(app)

        let filter = filterField(in: app)
        XCTAssertTrue(filter.waitForExistence(timeout: 10))
        XCTAssertTrue(hasKeyboardFocus(filter), "Precondition: filter is focused on open")

        beginRename(in: app)

        let handoffSteals = sampleFilterFocusSteals(app, duration: 2.5)
        XCTAssertEqual(handoffSteals, 0, "Filter must never hold focus during rename handoff")

        let rename = renameField(in: app)
        XCTAssertTrue(rename.exists, "Inline rename field should appear")
        XCTAssertTrue(hasKeyboardFocus(rename), "Rename should own focus after handoff")

        for character in ["X", "Y", "Z"] {
            app.typeText(character)
            XCTAssertTrue(hasKeyboardFocus(rename), "Rename must retain focus after typing \(character)")
            XCTAssertFalse(hasKeyboardFocus(filter), "Filter must not steal focus after typing \(character)")
            let steals = sampleFilterFocusSteals(app, duration: 0.8)
            XCTAssertEqual(steals, 0, "Filter must not bounce into focus after typing \(character)")
        }

        XCTAssertEqual(rename.value as? String, Self.fixtureStreamName + "XYZ")
        let filterValue = (filter.value as? String) ?? ""
        XCTAssertTrue(filterValue.isEmpty || filterValue == "Filter...")
    }

    @MainActor
    func testFailedRenameSubmitRestoresPickerFocusAndControls() throws {
        let app = launchFixtureApp()
        openPicker(app)
        beginRename(in: app)

        let rename = renameField(in: app)
        XCTAssertTrue(rename.waitForExistence(timeout: 6))
        app.typeText("Q")
        app.typeText("\n")

        assertPickerReadyAfterSubmit(app)
    }

    @MainActor
    func testEmptyRenameSubmitRestoresPickerFocusAndControls() throws {
        let app = launchFixtureApp()
        openPicker(app)
        beginRename(in: app)

        let rename = renameField(in: app)
        XCTAssertTrue(rename.waitForExistence(timeout: 6))
        rename.typeKey("a", modifierFlags: .command)
        rename.typeKey(.delete, modifierFlags: [])
        app.typeText("\n")

        assertPickerReadyAfterSubmit(app)
    }

    @MainActor
    func testDismissDuringRenameResetsPickerForNextOpen() throws {
        let app = launchFixtureApp()
        openPicker(app)
        beginRename(in: app)

        let rename = renameField(in: app)
        XCTAssertTrue(rename.waitForExistence(timeout: 6))
        app.typeText("X")

        app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.1)).tap()
        XCTAssertTrue(waitForExistence(rename, expected: false), "Outside tap should dismiss the picker")

        openPicker(app)
        let filter = filterField(in: app)
        XCTAssertTrue(filter.waitForExistence(timeout: 10))
        XCTAssertTrue(hasKeyboardFocus(filter), "Reopened picker should auto-focus the filter")

        let addStream = app.buttons["Add stream"].firstMatch
        XCTAssertTrue(addStream.waitForExistence(timeout: 6))
        XCTAssertTrue(addStream.isEnabled, "Dismiss should reset inline-edit control state")
    }
}
