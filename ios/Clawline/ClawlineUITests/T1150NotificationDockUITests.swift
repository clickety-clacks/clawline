import XCTest

final class T1150NotificationDockUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testDockedNotificationTapUndocksAllNotifications() throws {
        let app = launchDockedNotificationProofApp(skipCollapsedPreview: true)

        let dockedHitTarget = dockedHitTarget(in: app)
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: dockedHitTarget.frame.midX, dy: dockedHitTarget.frame.minY + 24))
            .tap()

        assertUndockedNotificationsRemainVisible(in: app)
    }

    @MainActor
    func testDockedNotificationLeftSwipeDoesNotDismissNotifications() throws {
        let app = launchDockedNotificationProofApp(skipCollapsedPreview: true)

        let dockedHitTarget = dockedHitTarget(in: app)
        let start = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: dockedHitTarget.frame.midX, dy: dockedHitTarget.frame.minY + 24))
        let end = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: dockedHitTarget.frame.midX - 80, dy: dockedHitTarget.frame.minY + 24))
        start.press(forDuration: 0.15, thenDragTo: end)

        assertUndockedNotificationsRemainVisible(in: app)
    }

    @MainActor
    func testPeekingNotificationLeftSwipeDismissesOnlyThatNotification() throws {
        let app = launchDockedNotificationProofApp(extendCollapsedPreview: true)
        let alpha = app.staticTexts["T1174 Alpha"]
        XCTAssertTrue(alpha.waitForExistence(timeout: 4), "Expected seeded notification to be peeking")
        let beta = app.staticTexts["T1174 Beta"]
        XCTAssertTrue(beta.waitForExistence(timeout: 4), "Expected second seeded notification to be peeking")
        let interactionPoint = alpha.frame.center

        let start = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: interactionPoint.x, dy: interactionPoint.y))
        let end = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: interactionPoint.x - 180, dy: interactionPoint.y))
        start.press(forDuration: 0.15, thenDragTo: end)

        XCTAssertFalse(app.staticTexts["T1174 Alpha"].waitForExistence(timeout: 1), "Peeking left swipe should dismiss only the swiped notification")
        XCTAssertTrue(app.staticTexts["T1174 Beta"].exists, "Peeking left swipe should preserve other notifications")
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
        XCTAssertTrue(beta.waitForExistence(timeout: 4), "Peeking right swipe should preserve other peeking notifications")

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
        XCTAssertTrue(app.staticTexts["T1174 Beta"].waitForExistence(timeout: 4), "Expected second seeded notification to be peeking")
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
        XCTAssertTrue(app.staticTexts["T1174 Beta"].exists, "Peeking tap should not dismiss another chat's notification")
    }

    @MainActor
    func testSameChatPeekingNotificationIsNotVisibleWhenAlreadyActiveChat() throws {
        let app = launchDockedNotificationProofApp(extendCollapsedPreview: true, startOnAlpha: true)
        XCTAssertTrue(app.staticTexts["T1174 Beta"].waitForExistence(timeout: 4), "Expected unrelated notification to be peeking")

        XCTAssertFalse(app.staticTexts["T1174 Alpha"].waitForExistence(timeout: 1), "The active chat's notification should not remain visible")
        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(identifier: "T1174 Alpha Chat proof message")
                .firstMatch
                .waitForExistence(timeout: 2),
            "Same-chat navigation should remain on the notification source chat"
        )
        XCTAssertTrue(app.staticTexts["T1174 Beta"].exists, "Same-chat navigation should not dismiss unrelated notifications")
    }

    @MainActor
    private func launchDockedNotificationProofApp(
        skipCollapsedPreview: Bool = false,
        extendCollapsedPreview: Bool = false,
        startOnAlpha: Bool = false
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

}

private extension CGRect {
    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }
}
