//
//  ClawlineUITests.swift
//  ClawlineUITests
//
//  Created by Mike Manzano on 1/7/26.
//

import XCTest

final class ClawlineUITests: XCTestCase {

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
}
