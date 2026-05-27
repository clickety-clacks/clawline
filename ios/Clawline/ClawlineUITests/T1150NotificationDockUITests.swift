import XCTest

final class T1150NotificationDockUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testDockedNotificationTapUndocksAllNotifications() throws {
        let app = launchDockedNotificationProofApp()

        let dockedHitTarget = dockedHitTarget(in: app)
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: dockedHitTarget.frame.midX, dy: dockedHitTarget.frame.minY + 24))
            .tap()

        assertUndockedNotificationsRemainVisible(in: app)
    }

    @MainActor
    func testDockedNotificationLeftSwipeDoesNotDismissNotifications() throws {
        let app = launchDockedNotificationProofApp()

        let dockedHitTarget = dockedHitTarget(in: app)
        let start = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: dockedHitTarget.frame.midX, dy: dockedHitTarget.frame.minY + 24))
        let end = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: dockedHitTarget.frame.midX - 80, dy: dockedHitTarget.frame.minY + 24))
        start.press(forDuration: 0.15, thenDragTo: end)

        assertUndockedNotificationsRemainVisible(in: app)
    }

    @MainActor
    private func launchDockedNotificationProofApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "-auth.token", "debug-token",
            "-auth.userId", "debug-user",
            "-auth.isAdmin", "YES",
            "-provider.baseURL", "ws://127.0.0.1:8080",
            "--debug-cross-chat-notification-dock-proof",
            "--debug-cross-chat-notification-dock-proof-start-docked",
        ]
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
        XCTAssertTrue(undockedStack.waitForExistence(timeout: 4), "Tapping a docked notification should undock all notifications")
        XCTAssertGreaterThanOrEqual(
            app.descendants(matching: .any).matching(identifier: "cross_chat_notification_stack_undocked").count,
            2,
            "Undocked stack should expose multiple seeded notification descendants"
        )
    }
}
