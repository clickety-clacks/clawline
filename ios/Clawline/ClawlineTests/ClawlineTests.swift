//
//  ClawlineTests.swift
//  ClawlineTests
//
//  Created by Mike Manzano on 1/7/26.
//

import Foundation
import Testing
import UIKit
@testable import Clawline

struct ClawlineTests {
    @Test("T167: font scale applies Catalyst platform delta before user multiplier")
    func scaledPointSizeUsesCatalystPlatformDeltaAndPersistedScale() {
        let suiteName = "ClawlineTests.T167.scaledPointSizeUsesCatalystPlatformDeltaAndPersistedScale"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("Failed to create isolated defaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let basePointSize: CGFloat = 20
        let expectedDefault: CGFloat
#if targetEnvironment(macCatalyst)
        expectedDefault = 24
#else
        expectedDefault = 20
#endif

        #expect(AppFontScale.scaledPointSize(for: basePointSize, defaults: defaults) == expectedDefault)

        AppFontScale.persist(1.5, defaults: defaults)
        #expect(
            AppFontScale.scaledPointSize(for: basePointSize, defaults: defaults)
                == expectedDefault * 1.5
        )
    }

    @Test("T134: font scale shortcuts adjust value and emit toast message")
    @MainActor
    func fontScaleAdjustmentsEmitToast() {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: AppFontScale.storageKey)
        defer {
            if let previous {
                defaults.set(previous, forKey: AppFontScale.storageKey)
            } else {
                defaults.removeObject(forKey: AppFontScale.storageKey)
            }
            AppFontScale.useActiveValue(AppFontScale.persistedValue())
        }
        defaults.removeObject(forKey: AppFontScale.storageKey)

        let settings = SettingsManager()
        #expect(settings.fontScale == AppFontScale.defaultValue)
        #expect(AppFontScale.currentValue() == settings.fontScale)

        settings.increaseFontScale()
        #expect(settings.fontScale == AppFontScale.defaultValue + AppFontScale.step)
        #expect(AppFontScale.currentValue() == settings.fontScale)
        #expect(settings.consumePendingFontScaleToastMessage() == "Font scale 110%")

        settings.decreaseFontScale()
        #expect(settings.fontScale == AppFontScale.defaultValue)
        #expect(AppFontScale.currentValue() == settings.fontScale)
        #expect(settings.consumePendingFontScaleToastMessage() == "Font scale 100%")
    }

    @Test("T134: app font scale clamps at configured limits")
    @MainActor
    func fontScaleClampsToBounds() {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: AppFontScale.storageKey)
        defer {
            if let previous {
                defaults.set(previous, forKey: AppFontScale.storageKey)
            } else {
                defaults.removeObject(forKey: AppFontScale.storageKey)
            }
            AppFontScale.useActiveValue(AppFontScale.persistedValue())
        }
        defaults.removeObject(forKey: AppFontScale.storageKey)

        let settings = SettingsManager()

        for _ in 0..<30 {
            settings.increaseFontScale()
        }
        #expect(settings.fontScale == AppFontScale.maximum)
        #expect(AppFontScale.currentValue() == AppFontScale.maximum)

        for _ in 0..<60 {
            settings.decreaseFontScale()
        }
        #expect(settings.fontScale == AppFontScale.minimum)
        #expect(AppFontScale.currentValue() == AppFontScale.minimum)
    }

    @Test("T180: placeholder text includes channel name and session key")
    func placeholderTextIncludesSessionKey() {
        #expect(
            ChatViewModel.placeholderText(
                displayName: "Main",
                sessionKey: "agent:main:clawline:flynn:main"
            ) == "Main — agent:main:clawline:flynn:main"
        )
        #expect(ChatViewModel.placeholderText(displayName: "Main", sessionKey: "") == "Main")
    }

    @Test("T001: Clawline personal terminal streams allow built-in and custom suffixes")
    func sessionKeyAllowsPersonalTerminalStreamSuffixes() {
        #expect(SessionKey.isClawlinePersonalDM("agent:main:clawline:flynn:main"))
        #expect(SessionKey.isClawlinePersonalDM("agent:main:clawline:flynn:dm"))
        #expect(SessionKey.isClawlinePersonalDM("agent:main:clawline:flynn:s_abcd1234"))
        #expect(SessionKey.isClawlinePersonalDM("agent:aux:clawline:flynn:s_abcd1234"))
    }

    @Test("T001: Clawline personal terminal streams reject invalid suffixes")
    func sessionKeyRejectsInvalidPersonalTerminalStreamSuffixes() {
        #expect(!SessionKey.isClawlinePersonalDM("agent:main:clawline:flynn:global_dm"))
        #expect(!SessionKey.isClawlinePersonalDM("agent:main:clawline:flynn:s_deadbee"))
        #expect(!SessionKey.isClawlinePersonalDM("agent:main:clawline:flynn:s_deadbeez"))
        #expect(!SessionKey.isClawlinePersonalDM("agent:main:clawline::main"))
        #expect(!SessionKey.isClawlinePersonalDM("server:main"))
    }

    @Test("T201: RootView keeps iOS system-follow by scoping preferredColorScheme to visionOS")
    func rootViewScopesPreferredColorSchemeToVisionOS() throws {
        let rootViewPath = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Clawline/Views/RootView.swift")
        let source = try String(contentsOf: rootViewPath, encoding: .utf8)
        let pattern = #"#if os\(visionOS\)[\s\S]*?\.preferredColorScheme\(settings\.preferredColorScheme\)[\s\S]*?#endif"#
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        let regex = try NSRegularExpression(pattern: pattern)

        #expect(regex.firstMatch(in: source, range: range) != nil)
    }

    @Test("T320: corner indicators stay Spatial-only")
    func cornerIndicatorsStaySpatialOnly() throws {
        let appPath = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Clawline/ClawlineApp.swift")
        let appSource = try String(contentsOf: appPath, encoding: .utf8)
        #expect(!appSource.contains("ClawlineWindowCornerIndicators"))

        let spatialAppPath = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Clawline Spatial/Clawline_SpatialApp.swift")
        let spatialAppSource = try String(contentsOf: spatialAppPath, encoding: .utf8)
        #expect(spatialAppSource.contains("ClawlineWindowCornerIndicators"))
    }

    @Test("T294: Spatial typing indicator exposes a concrete tap control")
    func spatialTypingIndicatorHasConcreteTapControl() throws {
        let sourcePath = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Clawline/Views/Chat/TypingIndicatorCell.swift")
        let source = try String(contentsOf: sourcePath, encoding: .utf8)
        let pattern = #"(?s)#if os\(visionOS\).*?spatialTapButton.*?UIButton\(type: \.custom\).*?addTarget\(self, action: #selector\(handleTap\), for: \.primaryActionTriggered\).*?#endif"#
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        let regex = try NSRegularExpression(pattern: pattern)

        #expect(regex.firstMatch(in: source, range: range) != nil)
    }

    @Test("T1429: typing indicator status text wraps inside bubble width")
    func typingIndicatorStatusTextWrapsInsideBubbleWidth() {
        #expect(TypingIndicatorCell.progressLabelWidth < TypingIndicatorCell.bubbleWidth)

        let singleLineHeight = TypingIndicatorCell.height(progressSummary: "Reading files")
        let wrappedHeight = TypingIndicatorCell.height(progressSummary: "Reading a very long status update from the current provider while scanning repository context")

        #expect(singleLineHeight == TypingIndicatorCell.bubbleHeight)
        #expect(wrappedHeight > TypingIndicatorCell.bubbleHeight)
    }

    @Test("T1483: typing indicator renders full-height bubble chrome")
    @MainActor
    func typingIndicatorRendersFullHeightBubbleChrome() {
        let progressSummary = "Reading a very long status update from the current provider while scanning repository context"
        let expectedHeight = TypingIndicatorCell.height(progressSummary: progressSummary)
        let cell = TypingIndicatorCell(frame: CGRect(
            x: 0,
            y: 0,
            width: TypingIndicatorCell.bubbleWidth,
            height: expectedHeight
        ))
        cell.contentView.frame = cell.bounds
        cell.configure(
            message: TypingIndicatorCell.makeMessage(sessionKey: "test-session"),
            presentation: TypingIndicatorCell.makePresentation(metrics: ChatFlowTheme.Metrics(isCompact: true)),
            isCompact: true,
            maxWidth: TypingIndicatorCell.bubbleWidth,
            progressSummary: progressSummary
        )

        cell.setNeedsLayout()
        cell.layoutIfNeeded()

        let renderedFrame = cell.renderedBubbleFrame(in: cell.contentView)
        #expect(renderedFrame.height >= expectedHeight - 0.5)
        #expect(renderedFrame.height > 40)
        writeT1483ProofImageIfRequested(cell: cell, renderedFrame: renderedFrame, expectedHeight: expectedHeight)
    }

    @MainActor
    private func writeT1483ProofImageIfRequested(
        cell: TypingIndicatorCell,
        renderedFrame: CGRect,
        expectedHeight: CGFloat
    ) {
        guard let proofDirectory = ProcessInfo.processInfo.environment["T1483_VISUAL_PROOF_DIR"],
              !proofDirectory.isEmpty else { return }
        let directoryURL = URL(filePath: proofDirectory, directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let image = UIGraphicsImageRenderer(bounds: cell.bounds).image { context in
                cell.layer.render(in: context.cgContext)
            }
            let outputURL = directoryURL.appending(path: "typing-indicator-cell.png")
            guard let pngData = image.pngData() else {
                Issue.record("Failed to encode T1483 visual proof image")
                return
            }
            try pngData.write(to: outputURL)
            print("T1483 geometry proof renderedFrame=\(renderedFrame) expectedHeight=\(expectedHeight) proofImage=\(outputURL.path)")
        } catch {
            Issue.record("Failed to write T1483 visual proof: \(error)")
        }
    }

    @Test("T1485: bubble geometry owns adjacent row rhythm")
    func bubbleGeometryOwnsAdjacentRowRhythm() {
        let compactMetrics = ChatFlowTheme.Metrics(isCompact: true)
        let regularMetrics = ChatFlowTheme.Metrics(isCompact: false)

        #expect(
            MessageBubbleGeometry.adjacentMessageRowSpacing(metrics: compactMetrics)
                == max(compactMetrics.containerPadding, 24)
        )
        #expect(
            MessageBubbleGeometry.adjacentMessageRowSpacing(metrics: regularMetrics)
                == max(regularMetrics.containerPadding, 24)
        )
        #expect(MessageBubbleGeometry.adjacentMessageRowSpacing(metrics: compactMetrics) >= 24)
        #expect(MessageBubbleGeometry.adjacentMessageRowSpacing(metrics: regularMetrics) >= 24)
    }

    @Test("T1485: normal bubble bottom blank space is only owned chrome inset")
    @MainActor
    func normalBubbleBottomBlankSpaceIsOnlyOwnedChromeInset() {
        let metrics = ChatFlowTheme.Metrics(isCompact: true)
        let message = Message(
            id: "t1485-short-message",
            role: .user,
            content: "Short geometry proof",
            timestamp: Date(timeIntervalSince1970: 0),
            streaming: false,
            attachments: [],
            deviceId: nil,
            sessionKey: "test-session"
        )
        let presentation = MessagePresentation(
            parts: [.text(message.content)],
            wordCount: 3,
            hasTextualContent: true,
            isEmojiOnly: false,
            hasMediaOnly: false,
            detectedURLs: [],
            detectedURLCount: 0,
            hasSingleURL: false
        )
        let bubble = MessageBubbleUIKitView()
        bubble.configure(
            message: message,
            presentation: presentation,
            sizeClass: .short,
            metrics: metrics,
            maxWidth: 220,
            onRequestExpand: nil,
            onRequestLayout: nil,
            onInteractiveCallback: nil
        )

        let measuredSize = bubble.systemLayoutSizeFitting(
            CGSize(width: 220, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        bubble.frame = CGRect(origin: .zero, size: measuredSize)
        bubble.setNeedsLayout()
        bubble.layoutIfNeeded()

        let geometry = bubble.renderedGeometryForTests(in: bubble)
        let ownedInsets = MessageBubbleGeometry.contentInsets(
            metrics: metrics,
            paddingScale: 1,
            hasTerminalSessions: false,
            hasMediaOnly: false
        )
        let bottomBlank = geometry.bubbleFrame.maxY - geometry.contentFrame.maxY

        #expect(abs(bottomBlank - ownedInsets.bottom) <= 0.5)
        #expect(geometry.dynamicContentFrame.maxY <= geometry.contentFrame.maxY + 0.5)
        #expect(geometry.bodyFrame.maxY <= geometry.contentFrame.maxY + 0.5)
        print(
            "T1485 geometry proof bubbleFrame=\(geometry.bubbleFrame) contentFrame=\(geometry.contentFrame) bodyFrame=\(geometry.bodyFrame) dynamicContentFrame=\(geometry.dynamicContentFrame) bottomBlank=\(bottomBlank) ownedBottomInset=\(ownedInsets.bottom) rowGap=\(MessageBubbleGeometry.adjacentMessageRowSpacing(metrics: metrics)) horizontalSide=\(metrics.containerPadding) horizontalBubbleGap=\(metrics.flowGap)"
        )
        writeT1485ProofImageIfRequested(bubble: bubble, geometry: geometry, bottomBlank: bottomBlank, ownedBottomInset: ownedInsets.bottom)
    }

    @MainActor
    private func writeT1485ProofImageIfRequested(
        bubble: MessageBubbleUIKitView,
        geometry: MessageBubbleRenderedGeometry,
        bottomBlank: CGFloat,
        ownedBottomInset: CGFloat
    ) {
        guard let proofDirectory = ProcessInfo.processInfo.environment["T1485_GEOMETRY_PROOF_DIR"],
              !proofDirectory.isEmpty else { return }
        let directoryURL = URL(filePath: proofDirectory, directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let image = UIGraphicsImageRenderer(bounds: bubble.bounds).image { context in
                bubble.layer.render(in: context.cgContext)
            }
            let outputURL = directoryURL.appending(path: "normal-bubble-geometry.png")
            guard let pngData = image.pngData() else {
                Issue.record("Failed to encode T1485 visual proof image")
                return
            }
            try pngData.write(to: outputURL)
            print("T1485 geometry proof image=\(outputURL.path) geometry=\(geometry) bottomBlank=\(bottomBlank) ownedBottomInset=\(ownedBottomInset)")
        } catch {
            Issue.record("Failed to write T1485 visual proof: \(error)")
        }
    }

    @Test("T127: Spatial chat viewport keeps 25 percent top and bottom insets")
    func spatialChatViewportKeepsQuarterWindowInsets() throws {
        let sourcePath = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Clawline/Views/Chat/ChatView.swift")
        let source = try String(contentsOf: sourcePath, encoding: .utf8)
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        let spatialInsetPattern = #"(?s)static func spatialViewportInset\(windowHeight: CGFloat\) -> CGFloat \{\s*#if os\(visionOS\)\s*windowHeight \* 0\.25\s*#else\s*0\s*#endif\s*\}"#
        let topInsetPattern = #"let messageListTopInset = geometry\.safeAreaInsets\.top \+ spatialViewportInset"#
        let bottomInsetPattern = #"let bottomViewportClearance = pageIndicatorClearance"#

        #expect(try NSRegularExpression(pattern: spatialInsetPattern).firstMatch(in: source, range: range) != nil)
        #expect(try NSRegularExpression(pattern: topInsetPattern).firstMatch(in: source, range: range) != nil)
        #expect(try NSRegularExpression(pattern: bottomInsetPattern).firstMatch(in: source, range: range) != nil)
        #expect(source.contains("spatialFooterBottomInset") == false)
    }

    @Test("T1422: Spatial notification transition scales and fades during trailing slide")
    func spatialNotificationTransitionAddsScaleWithoutChangingNativeTransition() throws {
        let sourcePath = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Clawline/Views/Chat/ChatView.swift")
        let source = try String(contentsOf: sourcePath, encoding: .utf8)
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        let spatialTransitionPattern = #"(?s)#if os\(visionOS\)\s*private static let notificationTransition = AnyTransition\.asymmetric\(\s*insertion: \.move\(edge: \.trailing\)\s*\.combined\(with: \.scale\(scale: 0\)\)\s*\.combined\(with: \.opacity\)\s*\.animation\(revealAnimation\),\s*removal: \.move\(edge: \.trailing\)\s*\.combined\(with: \.scale\(scale: 0\)\)\s*\.combined\(with: \.opacity\)\s*\.animation\(hideAnimation\)\s*\)\s*#else\s*private static let notificationTransition = AnyTransition\.asymmetric\(\s*insertion: \.move\(edge: \.trailing\)\s*\.combined\(with: \.opacity\)\s*\.animation\(revealAnimation\),\s*removal: \.move\(edge: \.trailing\)\s*\.combined\(with: \.opacity\)\s*\.animation\(hideAnimation\)\s*\)\s*#endif"#
        let regex = try NSRegularExpression(pattern: spatialTransitionPattern)

        #expect(regex.firstMatch(in: source, range: range) != nil)
    }

    @Test("T219: pairing shader is active only while pairing route is visible")
    func rootBackgroundShaderLifecycleFollowsPairingRoute() {
        #expect(RootBackgroundShaderLifecycle.isShaderActive(
            isAuthenticated: false,
            isProviderConfigured: false
        ))
        #expect(RootBackgroundShaderLifecycle.isShaderActive(
            isAuthenticated: false,
            isProviderConfigured: true
        ))
        #expect(RootBackgroundShaderLifecycle.isShaderActive(
            isAuthenticated: true,
            isProviderConfigured: false
        ))
        #expect(!RootBackgroundShaderLifecycle.isShaderActive(
            isAuthenticated: true,
            isProviderConfigured: true
        ))
    }

}
