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

    private func waitForKeyboardFocus(
        _ element: XCUIElement,
        expected: Bool = true,
        timeout: TimeInterval = 6
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                self.hasKeyboardFocus(element) == expected
            },
            object: nil
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
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
        let rename = renameField(in: app)
        let filter = filterField(in: app)
        XCTAssertTrue(rename.waitForExistence(timeout: 6), "Failed or empty submit should preserve the draft")
        XCTAssertTrue(waitForKeyboardFocus(rename, expected: false), "Submitted rename should release focus")
        XCTAssertTrue(waitForKeyboardFocus(filter), "Filter should regain focus after submit")

        let addStream = app.buttons["Add stream"].firstMatch
        XCTAssertTrue(addStream.waitForExistence(timeout: 6))
        XCTAssertTrue(addStream.isEnabled, "Add stream should be enabled after inline editing finishes")

        let track = app.buttons["Track"].firstMatch
        if track.exists {
            XCTAssertTrue(track.isEnabled, "Track should be enabled after inline editing finishes")
        }
    }

    @MainActor
    func testPickerOpenAutoFocusesFilterField() throws {
        let app = launchFixtureApp()
        openPicker(app)

        let filter = filterField(in: app)
        XCTAssertTrue(filter.waitForExistence(timeout: 10), "Picker open should render the filter field")
        XCTAssertTrue(waitForKeyboardFocus(filter), "Picker open should auto-focus the filter field")

        app.typeText("ab")
        XCTAssertEqual(filter.value as? String, "ab", "Keystrokes after open should land in the filter")
    }

    @MainActor
    func testRenameKeepsFocusAcrossMultipleKeystrokes() throws {
        let app = launchFixtureApp()
        openPicker(app)

        let filter = filterField(in: app)
        XCTAssertTrue(filter.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForKeyboardFocus(filter), "Precondition: filter is focused on open")

        beginRename(in: app)

        let rename = renameField(in: app)
        XCTAssertTrue(rename.waitForExistence(timeout: 6), "Inline rename field should appear")
        XCTAssertTrue(waitForKeyboardFocus(rename), "Rename should take focus when editing begins")

        for character in ["X", "Y", "Z"] {
            app.typeText(character)
            XCTAssertTrue(waitForKeyboardFocus(rename), "Rename must retain focus after typing \(character)")
            XCTAssertFalse(hasKeyboardFocus(filter), "Filter must not steal focus after typing \(character)")
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
        XCTAssertTrue(waitForKeyboardFocus(filter), "Reopened picker should auto-focus the filter")

        let addStream = app.buttons["Add stream"].firstMatch
        XCTAssertTrue(addStream.waitForExistence(timeout: 6))
        XCTAssertTrue(addStream.isEnabled, "Dismiss should reset inline-edit control state")
    }
}
