//
//  ClawlineUITests.swift
//  ClawlineUITests
//
//  Created by Mike Manzano on 1/7/26.
//

import XCTest
import UIKit

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
    func testT357LandscapeChatSurfaceCapture() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 8))

        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(6)

        XCTAssertGreaterThan(app.frame.width, app.frame.height, "Expected the app to be in iPhone landscape")

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "T357 Landscape Chat Surface"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testT1202ProductionLandscapeNoStreamStartupStaysWithinScreen() throws {
        XCUIDevice.shared.orientation = .portrait
        sleep(1)

        let app = XCUIApplication()
        app.launchArguments += [
            "-auth.token", "debug-token",
            "-auth.userId", "debug-user",
            "-auth.isAdmin", "YES",
            "-provider.baseURL", "ws://127.0.0.1:8080",
        ]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 8))

        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(2)

        XCTAssertGreaterThan(app.frame.width, app.frame.height, "Expected the app to be in iPhone landscape")

        let loadingState = waitForLoadingChats(in: app)
        assertElementStaysWithinScreen(loadingState, in: app, label: "loading state")

        let image = normalizedLandscapeImage(from: XCUIScreen.main.screenshot())
        writeImage(image, name: "t1202-landscape-edge-to-edge.png")
        assertLandscapeImageHasNoBlackSideGutters(image)

        let attachment = XCTAttachment(image: image)
        attachment.name = "T1202 Production Landscape No Stream Startup Edge To Edge"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testLaunchPerformance() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "-auth.token", "debug-token",
            "-auth.userId", "debug-user",
            "-auth.isAdmin", "YES",
            "-provider.baseURL", "ws://127.0.0.1:8080",
        ]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10), "App should launch successfully")
        app.terminate()
    }

    private func waitForLoadingChats(in app: XCUIApplication) -> XCUIElement {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            let label = app.staticTexts["Loading chats..."]
            if label.exists && label.frame.width > 40 && label.frame.height > 10 {
                return label
            }
            let indicator = app.activityIndicators["Loading chats"]
            if indicator.exists && indicator.frame.width > 0 && indicator.frame.height > 0 {
                return indicator
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTFail("Expected loading chats startup state to render")
        return app.staticTexts["Loading chats..."]
    }

    private func assertElementStaysWithinScreen(_ element: XCUIElement, in app: XCUIApplication, label: String) {
        XCTAssertGreaterThan(element.frame.width, 0, "\(label) should have positive width")
        XCTAssertGreaterThan(element.frame.height, 0, "\(label) should have positive height")
        XCTAssertGreaterThanOrEqual(element.frame.minX, app.frame.minX, "\(label) should not clip past the left screen edge")
        XCTAssertLessThanOrEqual(element.frame.maxX, app.frame.maxX, "\(label) should not clip past the right screen edge")
    }

    private func writeImage(_ image: UIImage, name: String) {
        let outputURL = visualProofDirectory()
            .appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            guard let pngData = image.pngData() else {
                XCTFail("Unable to encode visual proof screenshot")
                return
            }
            try pngData.write(to: outputURL, options: .atomic)
        } catch {
            XCTFail("Unable to write visual proof screenshot: \(error)")
        }
    }

    private func visualProofDirectory() -> URL {
        if let path = ProcessInfo.processInfo.environment["TEST_RUNNER_T1202_VISUAL_PROOF_DIR"]
            ?? ProcessInfo.processInfo.environment["T1202_VISUAL_PROOF_DIR"] {
            return URL(fileURLWithPath: path)
        }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("clawline-t1202-landscape-safezone", isDirectory: true)
    }

    private func normalizedLandscapeImage(from screenshot: XCUIScreenshot) -> UIImage {
        guard let image = UIImage(data: screenshot.pngRepresentation) else {
            XCTFail("Expected readable screenshot image")
            return UIImage()
        }
        guard let cgImage = image.cgImage else {
            XCTFail("Expected readable screenshot pixels")
            return image
        }
        guard cgImage.width < cgImage.height else {
            return image
        }

        let sourceSize = CGSize(width: cgImage.width, height: cgImage.height)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: sourceSize.height, height: sourceSize.width),
            format: format
        )
        return renderer.image { context in
            let cgContext = context.cgContext
            cgContext.translateBy(x: sourceSize.height / 2, y: sourceSize.width / 2)
            cgContext.rotate(by: -.pi / 2)
            image.draw(in: CGRect(
                x: -sourceSize.width / 2,
                y: -sourceSize.height / 2,
                width: sourceSize.width,
                height: sourceSize.height
            ))
        }
    }

    private func assertLandscapeImageHasNoBlackSideGutters(_ image: UIImage) {
        guard let cgImage = image.cgImage,
              let providerData = cgImage.dataProvider?.data,
              let bytes = CFDataGetBytePtr(providerData) else {
            XCTFail("Expected readable screenshot pixel data")
            return
        }

        let width = cgImage.width
        let height = cgImage.height
        XCTAssertGreaterThan(width, height, "Expected landscape screenshot")

        let bytesPerPixel = cgImage.bitsPerPixel / 8
        let bytesPerRow = cgImage.bytesPerRow
        XCTAssertGreaterThanOrEqual(bytesPerPixel, 4, "Expected RGBA-like screenshot pixels")

        let sideColumns = min(8, max(1, width / 40))
        let top = height / 5
        let bottom = height - top
        var sampled = 0
        var black = 0

        for y in top..<bottom {
            for x in 0..<sideColumns {
                if isBlackPixel(bytes: bytes, offset: y * bytesPerRow + x * bytesPerPixel) {
                    black += 1
                }
                sampled += 1
            }
            for x in (width - sideColumns)..<width {
                if isBlackPixel(bytes: bytes, offset: y * bytesPerRow + x * bytesPerPixel) {
                    black += 1
                }
                sampled += 1
            }
        }

        let blackRatio = sampled == 0 ? 1 : Double(black) / Double(sampled)
        XCTAssertLessThan(
            blackRatio,
            0.02,
            "Expected landscape chat/background to extend edge-to-edge without black left/right gutters; black edge pixel ratio was \(blackRatio)"
        )
    }

    private func isBlackPixel(bytes: UnsafePointer<UInt8>, offset: Int) -> Bool {
        let red = Int(bytes[offset])
        let green = Int(bytes[offset + 1])
        let blue = Int(bytes[offset + 2])
        return red < 8 && green < 8 && blue < 8
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
