import XCTest

final class T1150NotificationDockUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testDockedNotificationTapUndocksAllNotifications() throws {
        let app = launchDockedNotificationProofApp(skipCollapsedPreview: true)
        assertDockedPeekIsOnlyEdgeStrip(in: app)

        let dockedHitTarget = dockedHitTarget(in: app)
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: dockedHitTarget.frame.minX + 4, dy: dockedHitTarget.frame.midY))
            .tap()

        assertUndockedNotificationsRemainVisible(in: app)
        assertUndockedNotificationsAlignToTrailingEdge(in: app)
        attachLandscapeScreenshot(from: app, name: "T1150 rotated trailing notification proof")
    }

    @MainActor
    func testT1591NotificationGlobalShortcutsReachVisibleNotificationsWhileComposerIsFocused() throws {
        let app = launchDockedNotificationProofApp(skipCollapsedPreview: true)
        let dockedHitTarget = dockedHitTarget(in: app)
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: dockedHitTarget.frame.minX + 4, dy: dockedHitTarget.frame.midY))
            .tap()
        assertUndockedNotificationsRemainVisible(in: app)

        let composer = promptComposer(in: app)
        composer.tap()

        composer.typeKey("0", modifierFlags: [.command, .alternate])
        XCTAssertTrue(
            app.buttons["Close reply"].firstMatch.waitForExistence(timeout: 2),
            "Cmd-Option-0 should open reply for the first assigned notification while the composer is focused"
        )

        app.typeKey("0", modifierFlags: [.command, .shift, .alternate])
        XCTAssertFalse(
            app.staticTexts["T1174 Alpha"].waitForExistence(timeout: 1),
            "Cmd-Shift-Option-0 should dismiss the first assigned notification while its reply is focused"
        )
        XCTAssertTrue(app.staticTexts["T1174 Beta"].exists, "Assigned dismiss should preserve unrelated notifications")

        app.typeKey("-", modifierFlags: [.command, .shift, .alternate])
        XCTAssertFalse(
            app.staticTexts["T1174 Beta"].waitForExistence(timeout: 1),
            "Cmd-Shift-Option-minus should clear the remaining notifications"
        )
    }

    @MainActor
    func testT1591AssignedOpenShortcutPresentsNotificationActionMenu() throws {
        let app = launchDockedNotificationProofApp(skipCollapsedPreview: true)
        let composer = promptComposer(in: app)
        composer.tap()

        composer.typeKey("0", modifierFlags: [.command])

        XCTAssertTrue(
            app.descendants(matching: .any)["Go to Chat…"].waitForExistence(timeout: 2),
            "Cmd-0 should present the assigned notification action menu while the composer is focused"
        )
    }

    @MainActor
    func testT1591NotificationDockShortcutExecutesOnceWhileComposerIsFocused() throws {
        let app = launchDockedNotificationProofApp(skipCollapsedPreview: true)
        let dockedHitTarget = dockedHitTarget(in: app)
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: dockedHitTarget.frame.minX + 4, dy: dockedHitTarget.frame.midY))
            .tap()
        assertUndockedNotificationsRemainVisible(in: app)

        promptComposer(in: app).tap()
        app.typeKey("\\", modifierFlags: .command)

        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(identifier: "cross_chat_notification_stack_docked")
                .firstMatch
                .waitForExistence(timeout: 2),
            "Cmd-\\ should dock the notification stack exactly once while the composer is focused"
        )
        XCTAssertFalse(
            app.descendants(matching: .any)
                .matching(identifier: "cross_chat_notification_stack_undocked")
                .firstMatch
                .exists,
            "A second notification-stack owner must not immediately undo Cmd-\\"
        )
    }

    @MainActor
    func testRotatedLandscapeChatBubblesComposerAndNotificationsStayWithinScreen() throws {
        let app = launchDockedNotificationProofApp(skipCollapsedPreview: true)
        assertDockedPeekIsOnlyEdgeStrip(in: app)
        assertLandscapeChatProofContentIsVisible(in: app)

        let dockedHitTarget = dockedHitTarget(in: app)
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: dockedHitTarget.frame.minX + 4, dy: dockedHitTarget.frame.midY))
            .tap()

        assertUndockedNotificationsRemainVisible(in: app)
        assertUndockedNotificationsAlignToTrailingEdge(in: app)
        assertLandscapeChatProofContentIsVisible(in: app)
        attachLandscapeScreenshot(from: app, name: "T357 rotated chat and notification proof")
    }

    @MainActor
    func testDockedNotificationLeftSwipeDoesNotDismissNotifications() throws {
        let app = launchDockedNotificationProofApp(skipCollapsedPreview: true)

        let dockedHitTarget = dockedHitTarget(in: app)
        let start = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: dockedHitTarget.frame.midX, dy: dockedHitTarget.frame.midY))
        let end = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: dockedHitTarget.frame.midX - 80, dy: dockedHitTarget.frame.midY))
        start.press(forDuration: 0.15, thenDragTo: end)

        assertUndockedNotificationsRemainVisible(in: app)
    }

    @MainActor
    func testPeekingNotificationLeftSwipeDismissesOnlyThatNotification() throws {
        let app = launchDockedNotificationProofApp(extendCollapsedPreview: true)
        let alpha = app.staticTexts["T1174 Alpha"]
        XCTAssertTrue(alpha.waitForExistence(timeout: 4), "Expected seeded notification to be peeking")
        let beta = app.staticTexts["T1174 Beta"]
        XCTAssertFalse(beta.isHittable, "P8 permits only the single active docked notification to peek")
        let interactionPoint = alpha.frame.center

        let start = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: interactionPoint.x, dy: interactionPoint.y))
        let end = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: interactionPoint.x - 180, dy: interactionPoint.y))
        start.press(forDuration: 0.15, thenDragTo: end)

        XCTAssertFalse(app.staticTexts["T1174 Alpha"].waitForExistence(timeout: 1), "Peeking left swipe should dismiss only the swiped notification")
        let dockedHitTarget = dockedHitTarget(in: app)
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: dockedHitTarget.frame.midX, dy: dockedHitTarget.frame.minY + 24))
            .tap()
        XCTAssertTrue(app.staticTexts["T1174 Beta"].waitForExistence(timeout: 4), "Peeking left swipe should preserve other notifications")
    }

    @MainActor
    func testPeekingNotificationRightSwipeImmediatelyDocksNotification() throws {
        let app = launchDockedNotificationProofApp()
        let alpha = app.staticTexts["T1174 Alpha"]
        XCTAssertTrue(alpha.waitForExistence(timeout: 4), "Expected seeded notification to be peeking")
        let interactionPoint = alpha.frame.center

        let start = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: interactionPoint.x, dy: interactionPoint.y))
        let end = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: interactionPoint.x + 180, dy: interactionPoint.y))
        start.press(forDuration: 0.15, thenDragTo: end)

        let beta = app.staticTexts["T1174 Beta"]
        XCTAssertFalse(app.staticTexts["T1174 Alpha"].isHittable, "Peeking right swipe should move the swiped notification out of the peeking surface")
        XCTAssertFalse(beta.isHittable, "P8 keeps unrelated notifications docked instead of peeking concurrently")

        let dockedHitTarget = dockedHitTarget(in: app)
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: dockedHitTarget.frame.midX, dy: dockedHitTarget.frame.minY + 24))
            .tap()

        XCTAssertTrue(app.staticTexts["T1174 Alpha"].waitForExistence(timeout: 4), "Peeking right swipe should dock, not dismiss, the swiped notification")
        XCTAssertTrue(app.staticTexts["T1174 Beta"].exists, "Restoring the dock should preserve unrelated notifications")
    }

    @MainActor
    func testPeekingNotificationTapNavigatesToChatAndDismissesThatChatNotification() throws {
        let app = launchDockedNotificationProofApp(extendCollapsedPreview: true)
        let alpha = app.staticTexts["T1174 Alpha"]
        XCTAssertTrue(alpha.waitForExistence(timeout: 4), "Expected seeded chat-backed notification to be peeking")
        XCTAssertFalse(app.staticTexts["T1174 Beta"].isHittable, "P8 permits only the active docked notification to peek")
        let interactionPoint = alpha.frame.center

        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: interactionPoint.x, dy: interactionPoint.y))
            .tap()

        XCTAssertFalse(app.staticTexts["T1174 Alpha"].waitForExistence(timeout: 1), "Normal chat navigation should dismiss that chat's notification")
        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(identifier: "T1174 Alpha Chat proof message")
                .firstMatch
                .waitForExistence(timeout: 2),
            "Peeking tap should navigate to the notification source chat"
        )
        XCTAssertFalse(app.staticTexts["T1174 Beta"].isHittable, "Peeking tap should not undock another chat's notification")
    }

    @MainActor
    func testT1265DockedSinglePeekHandsOffToNewestEligibleNotification() throws {
        let app = launchDockedNotificationProofApp(
            extendCollapsedPreview: true,
            singlePeekHandoff: true
        )
        let alpha = app.staticTexts["T1174 Alpha"]
        XCTAssertTrue(alpha.waitForExistence(timeout: 4), "Expected the first seeded notification to start as the single peek")
        XCTAssertFalse(app.staticTexts["T1174 Beta"].isHittable, "Expected the second seeded notification to remain docked before new output")
        attachLandscapeScreenshot(from: app, name: "T1265 before single-peek handoff")

        let beta = app.staticTexts["T1174 Beta"]
        XCTAssertTrue(beta.waitForExistence(timeout: 5), "New eligible assistant output should make Beta the single peeking notification")
        XCTAssertTrue(app.staticTexts["T1174 Alpha"].exists, "The previously peeking Alpha notification should remain in the docked stack")
        XCTAssertFalse(app.staticTexts["T1174 Alpha"].isHittable, "The previously peeking Alpha notification should return to the docked stack")
        assertElementStaysWithinScreen(beta, in: app, label: "T1265 handoff notification")
        attachLandscapeScreenshot(from: app, name: "T1265 after single-peek handoff")
    }

    @MainActor
    func testNotificationTapNavigatesOnFirstTapWhenKeyboardIsUp() throws {
        let app = launchDockedNotificationProofApp(skipCollapsedPreview: true)
        let dockedHitTarget = dockedHitTarget(in: app)
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: dockedHitTarget.frame.midX, dy: dockedHitTarget.frame.minY + 24))
            .tap()

        let alpha = app.staticTexts["T1174 Alpha"]
        XCTAssertTrue(alpha.waitForExistence(timeout: 4), "Expected seeded chat-backed notification to be visible")

        let composer = promptComposer(in: app)
        composer.tap()
        composer.typeText("keyboard active")

        let interactionPoint = CGPoint(x: alpha.frame.midX, y: alpha.frame.maxY + 18)
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: interactionPoint.x, dy: interactionPoint.y))
            .tap()

        XCTAssertFalse(app.staticTexts["T1174 Alpha"].waitForExistence(timeout: 1), "First tap with keyboard up should dismiss that chat's notification")
        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(identifier: "T1174 Alpha Chat proof message")
                .firstMatch
                .waitForExistence(timeout: 2),
            "First tap with keyboard up should navigate to the notification source chat"
        )
    }

    @MainActor
    func testNotificationReplyAndCloseControlsAreSingleTapActivatable() throws {
        let app = launchDockedNotificationProofApp(skipCollapsedPreview: true)

        let dockedHitTarget = dockedHitTarget(in: app)
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: dockedHitTarget.frame.midX, dy: dockedHitTarget.frame.minY + 24))
            .tap()

        let replyButton = app.buttons["Reply"].firstMatch
        XCTAssertTrue(replyButton.waitForExistence(timeout: 4), "Expected notification Reply control to exist")
        replyButton.tap()

        let closeReplyButton = app.buttons["Close reply"].firstMatch
        XCTAssertTrue(closeReplyButton.waitForExistence(timeout: 2), "Reply tap should open the notification reply flow")
        closeReplyButton.tap()

        XCTAssertTrue(app.buttons["Reply"].firstMatch.waitForExistence(timeout: 2), "Close reply tap should close the notification reply flow")
    }

    @MainActor
    func testNotificationDismissControlIsSingleTapActivatable() throws {
        let app = launchDockedNotificationProofApp(skipCollapsedPreview: true)

        let dockedHitTarget = dockedHitTarget(in: app)
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: dockedHitTarget.frame.midX, dy: dockedHitTarget.frame.minY + 24))
            .tap()

        let alpha = app.staticTexts["T1174 Alpha"]
        XCTAssertTrue(alpha.waitForExistence(timeout: 4), "Expected seeded notification to be visible")

        let dismissButton = app.buttons["Dismiss"].firstMatch
        XCTAssertTrue(dismissButton.waitForExistence(timeout: 4), "Expected notification Dismiss control to exist")
        dismissButton.tap()

        XCTAssertFalse(app.staticTexts["T1174 Alpha"].waitForExistence(timeout: 1), "Dismiss tap should close that notification")
        XCTAssertTrue(app.staticTexts["T1174 Beta"].exists, "Dismiss tap should preserve unrelated notifications")
    }

    @MainActor
    func testNotificationContentDragDoesNotScrollChatUnderneath() throws {
        let app = launchDockedNotificationProofApp(skipCollapsedPreview: true)

        let dockedHitTarget = dockedHitTarget(in: app)
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: dockedHitTarget.frame.midX, dy: dockedHitTarget.frame.minY + 24))
            .tap()

        let alpha = app.staticTexts["T1174 Alpha"]
        XCTAssertTrue(alpha.waitForExistence(timeout: 4), "Expected seeded notification to be visible")
        let scrollToBottomButton = app.buttons["scroll_to_bottom_button"]
        if scrollToBottomButton.waitForExistence(timeout: 1) {
            scrollToBottomButton.tap()
        }
        XCTAssertFalse(
            scrollToBottomButton.waitForExistence(timeout: 1),
            "Expected seeded main chat to start without a visible scroll-to-bottom button before notification content drag"
        )

        let start = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: alpha.frame.midX, dy: alpha.frame.maxY + 18))
        let end = start.withOffset(CGVector(dx: 0, dy: 160))
        start.press(forDuration: 0.15, thenDragTo: end)

        XCTAssertFalse(
            scrollToBottomButton.waitForExistence(timeout: 1),
            "Dragging over notification content should not scroll the chat underneath"
        )
        XCTAssertTrue(app.staticTexts["T1174 Alpha"].exists, "Notification should remain visible after content drag")
    }

    @MainActor
    func testSameChatPeekingNotificationIsNotVisibleWhenAlreadyActiveChat() throws {
        let app = launchDockedNotificationProofApp(extendCollapsedPreview: true, startOnAlpha: true)
        XCTAssertTrue(app.staticTexts["T1174 Beta"].waitForExistence(timeout: 4), "Expected unrelated notification to be peeking")

        XCTAssertFalse(app.staticTexts["T1174 Alpha"].waitForExistence(timeout: 1), "The active chat's notification should not remain visible")
        XCTAssertTrue(app.staticTexts["T1174 Beta"].exists, "Same-chat navigation should not dismiss unrelated notifications")
    }

    @MainActor
    private func launchDockedNotificationProofApp(
        skipCollapsedPreview: Bool = false,
        extendCollapsedPreview: Bool = false,
        startOnAlpha: Bool = false,
        singlePeekHandoff: Bool = false
    ) -> XCUIApplication {
        XCUIDevice.shared.orientation = .landscapeLeft

        let app = XCUIApplication()
        app.launchArguments += [
            "-auth.token", "debug-token",
            "-auth.userId", "debug-user",
            "-auth.isAdmin", "YES",
            "-provider.baseURL", "ws://127.0.0.1:8080",
            "--debug-cross-chat-notification-dock-proof",
            "--debug-cross-chat-notification-dock-proof-start-docked",
        ]
        if skipCollapsedPreview {
            app.launchArguments.append("--debug-cross-chat-notification-dock-proof-skip-preview")
        }
        if extendCollapsedPreview {
            app.launchArguments.append("--debug-cross-chat-notification-dock-proof-extended-preview")
        }
        if startOnAlpha {
            app.launchArguments.append("--debug-cross-chat-notification-dock-proof-start-on-alpha")
        }
        if singlePeekHandoff {
            app.launchArguments.append("--debug-cross-chat-notification-dock-proof-single-peek-handoff")
        }
        app.launch()

        let dockedStack = app.descendants(matching: .any)
            .matching(identifier: "cross_chat_notification_stack_docked")
            .firstMatch
        XCTAssertTrue(dockedStack.waitForExistence(timeout: 8), "Expected seeded notifications to start docked")
        return app
    }

    private func dockedHitTarget(in app: XCUIApplication) -> XCUIElement {
        let dockedHitTarget = app.descendants(matching: .any)
            .matching(identifier: "cross_chat_notification_docked_hit_target")
            .firstMatch
        XCTAssertTrue(dockedHitTarget.waitForExistence(timeout: 4), "Expected docked notification hit target to exist")
        return dockedHitTarget
    }

    private func promptComposer(in app: XCUIApplication) -> XCUIElement {
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            let promptInput = app.textViews["prompt_input"]
            if promptInput.exists && promptInput.isHittable {
                return promptInput
            }

            let composeTextView = app.textViews["compose-text-view"]
            if composeTextView.exists && composeTextView.isHittable {
                return composeTextView
            }

            let candidates = app.textViews.allElementsBoundByIndex
                .filter { $0.exists && $0.isHittable && $0.frame.width > 40 && $0.frame.height > 20 }
                .sorted { $0.frame.midY > $1.frame.midY }
            if let composer = candidates.first {
                return composer
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTFail("Expected prompt composer text view to exist")
        return app.textViews.firstMatch
    }

    private func assertUndockedNotificationsRemainVisible(in app: XCUIApplication) {
        let undockedStack = app.descendants(matching: .any)
            .matching(identifier: "cross_chat_notification_stack_undocked")
            .firstMatch
        XCTAssertTrue(
            undockedStack.waitForExistence(timeout: 4),
            "Tapping a docked notification should undock all notifications; docked target frame=\(dockedHitTarget(in: app).frame) hittable=\(dockedHitTarget(in: app).isHittable)"
        )
        XCTAssertGreaterThanOrEqual(
            app.descendants(matching: .any).matching(identifier: "cross_chat_notification_stack_undocked").count,
            2,
            "Undocked stack should expose multiple seeded notification descendants"
        )
    }

    private func assertDockedPeekIsOnlyEdgeStrip(in app: XCUIApplication) {
        let hitTarget = dockedHitTarget(in: app)
        XCTAssertLessThanOrEqual(hitTarget.frame.width, 96, "Docked state should expose only the trailing edge affordance hit area")
        XCTAssertGreaterThanOrEqual(hitTarget.frame.maxX, app.frame.maxX - 2, "Docked peek strip should sit at the physical trailing edge")
        XCTAssertGreaterThanOrEqual(hitTarget.frame.minX, app.frame.maxX - 100, "Docked hit area should stay attached to the physical trailing edge")
    }

    private func assertUndockedNotificationsAlignToTrailingEdge(in app: XCUIApplication) {
        let alpha = app.staticTexts["T1174 Alpha"]
        XCTAssertTrue(alpha.waitForExistence(timeout: 4), "Expected seeded notification to be visible after undocking")
        XCTAssertGreaterThanOrEqual(alpha.frame.minX, app.frame.minX, "Undocked notification content should not clip past the left screen edge")
        XCTAssertLessThanOrEqual(alpha.frame.maxX, app.frame.maxX, "Undocked notification content should not clip past the right screen edge")
        XCTAssertGreaterThan(alpha.frame.midX, app.frame.midX, "Undocked notification should align to the trailing dock zone, not float mid-screen")
    }

    private func assertLandscapeChatProofContentIsVisible(in app: XCUIApplication) {
        XCTAssertGreaterThan(app.frame.width, app.frame.height, "Expected rotated landscape simulator geometry")

        let incoming = app.descendants(matching: .any)
            .matching(identifier: "T357 landscape incoming proof message")
            .firstMatch
        XCTAssertTrue(incoming.waitForExistence(timeout: 4), "Expected incoming chat proof bubble to render")

        let outgoing = app.descendants(matching: .any)
            .matching(identifier: "T357 landscape outgoing proof message")
            .firstMatch
        XCTAssertTrue(outgoing.waitForExistence(timeout: 4), "Expected outgoing chat proof bubble to render")

        assertElementStaysWithinScreen(incoming, in: app, label: "incoming chat proof bubble")
        assertElementStaysWithinScreen(outgoing, in: app, label: "outgoing chat proof bubble")
    }

    private func assertElementStaysWithinScreen(_ element: XCUIElement, in app: XCUIApplication, label: String) {
        XCTAssertGreaterThan(element.frame.width, 0, "\(label) should have positive width")
        XCTAssertGreaterThan(element.frame.height, 0, "\(label) should have positive height")
        XCTAssertGreaterThanOrEqual(element.frame.minX, app.frame.minX, "\(label) should not clip past the left screen edge")
        XCTAssertLessThanOrEqual(element.frame.maxX, app.frame.maxX, "\(label) should not clip past the right screen edge")
    }

    private func attachLandscapeScreenshot(from app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

}

private extension CGRect {
    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }
}
