//
//  MessageInputBarBoundaryTests.swift
//  ClawlineTests
//
//  Created by Codex on 3/4/26.
//

import Testing
import CoreGraphics
import Foundation
import SwiftUI
import UIKit
@testable import Clawline

struct MessageInputBarBoundaryTests {
    @Test("T080 slice-2: submit intent is separated from transport send gating")
    func submitIntentGateUsesDraftAndSendActivityOnly() {
        #expect(MessageInputBar.shouldDispatchEditorSubmitIntent(
            isSending: false,
            hasSubmittableDraft: true
        ))
        #expect(!MessageInputBar.shouldDispatchEditorSubmitIntent(
            isSending: true,
            hasSubmittableDraft: true
        ))
        #expect(!MessageInputBar.shouldDispatchEditorSubmitIntent(
            isSending: false,
            hasSubmittableDraft: false
        ))
    }

    @Test("Send button bubble grows from ghost to active instead of fading")
    @MainActor
    func sendButtonBubbleUsesScaleStateForConnectedTransitions() {
        let ghostState = MessageInputBar.sendButtonBubbleVisualState(
            isSending: false,
            canSend: false,
            isStagingAttachments: false,
            connectionState: .connected
        )
        let activeState = MessageInputBar.sendButtonBubbleVisualState(
            isSending: false,
            canSend: true,
            isStagingAttachments: false,
            connectionState: .connected
        )

        #expect(ghostState == .ghost)
        #expect(activeState == .active)
        #expect(MessageInputBar.sendButtonBubbleScale(state: ghostState) == 0)
        #expect(MessageInputBar.sendButtonBubbleScale(state: activeState) == 1)
    }

    @Test("Reconnect bubble keeps the 0.75 small-end scale")
    @MainActor
    func reconnectBubbleRetainsRequestedSmallEndScale() {
        #expect(MessageInputBar.reconnectBubbleScale(phase: CGFloat(0)) == CGFloat(0.75))
        #expect(MessageInputBar.reconnectBubbleScale(phase: CGFloat(1)) == CGFloat(1.0))
        #expect(
            abs(
                MessageInputBar.sendButtonBubbleScale(
                    state: .reconnecting,
                    reconnectPhase: 0
                ) - 0.75
            ) < 0.0001
        )
        #expect(
            abs(
                MessageInputBar.sendButtonBubbleScale(
                    state: .reconnecting,
                    reconnectPhase: 1
                ) - 1.0
            ) < 0.0001
        )
    }

    @Test("Preparing spinner keeps the send bubble active without enabling send")
    @MainActor
    func preparingSpinnerUsesConnectedActiveBubbleGate() {
        #expect(
            MessageInputBar.sendButtonShowsPreparingSpinner(
                isSending: false,
                canSend: false,
                isStagingAttachments: true,
                connectionState: .connected
            )
        )
        #expect(
            MessageInputBar.sendButtonBubbleVisualState(
                isSending: false,
                canSend: false,
                isStagingAttachments: true,
                connectionState: .connected
            ) == .active
        )
        #expect(
            !MessageInputBar.sendButtonShowsPreparingSpinner(
                isSending: false,
                canSend: false,
                isStagingAttachments: true,
                connectionState: .reconnecting
            )
        )
    }

    @Test("Reconnect state keeps the primary send icon visible while pulsing")
    @MainActor
    func reconnectStateRetainsPaperPlaneIcon() {
        #expect(
            MessageInputBar.sendButtonShowsPrimaryIcon(
                isSending: false,
                canSend: false,
                isStagingAttachments: false,
                connectionState: .reconnecting
            )
        )
        #expect(
            MessageInputBar.sendButtonPrimarySymbolName(connectionState: .reconnecting)
                == "paperplane.fill"
        )
    }

    @Test("Editor tap requests focus when keyboard is hidden")
    func editorTapRequestsFocusWhenKeyboardHidden() {
        #expect(MessageInputBar.shouldRequestFocusOnEditorTap(isKeyboardVisible: false))
        #expect(!MessageInputBar.shouldRequestFocusOnEditorTap(isKeyboardVisible: true))
    }

    @Test("T1566 attachment plus presents from a closed menu")
    func attachmentPlusPresentsFromClosedMenu() {
        #expect(AttachmentMenuPresentationPolicy.action(isCurrentlyPresented: false) == .present)
    }

    @Test("T1566 attachment plus refreshes a stale presented route")
    func attachmentPlusRefreshesStalePresentedRoute() {
        #expect(AttachmentMenuPresentationPolicy.action(isCurrentlyPresented: true) == .resetThenPresent)
    }

    @Test("Focus trigger cycles first responder only when keyboard collapsed under focus")
    func focusTriggerCyclesFirstResponderOnlyForHiddenKeyboard() {
        #expect(
            RichTextEditor.Coordinator.shouldCycleFirstResponder(
                isFirstResponder: true,
                isKeyboardVisible: false
            )
        )
        #expect(
            !RichTextEditor.Coordinator.shouldCycleFirstResponder(
                isFirstResponder: false,
                isKeyboardVisible: false
            )
        )
        #expect(
            !RichTextEditor.Coordinator.shouldCycleFirstResponder(
                isFirstResponder: true,
                isKeyboardVisible: true
            )
        )
    }

    @Test("T1361 invalid-width height retries coalesce until layout has a real width")
    @MainActor
    func invalidWidthHeightRetriesCoalesceUntilLayoutHasRealWidth() async {
        var attributedText = NSAttributedString(string: "one\ntwo\nthree\nfour\nfive")
        var calculatedHeight: CGFloat = 44
        var selectionRange = NSRange(location: 0, length: 0)
        var pendingInsertions: [PendingAttachment] = []
        let editor = RichTextEditor(
            attributedText: Binding(get: { attributedText }, set: { attributedText = $0 }),
            calculatedHeight: Binding(get: { calculatedHeight }, set: { calculatedHeight = $0 }),
            selectionRange: Binding(get: { selectionRange }, set: { selectionRange = $0 }),
            pendingInsertions: Binding(get: { pendingInsertions }, set: { pendingInsertions = $0 }),
            fontScaleChangeSequence: 0,
            resetToken: 0,
            focusTrigger: 0,
            dismissTrigger: 0,
            isEditable: true,
            isKeyboardVisible: false,
            tintColor: .systemBlue,
            onFocusChange: { _ in }
        )
        let coordinator = RichTextEditor.Coordinator(parent: editor)
        let textView = HeightProbeTextView(frame: .zero, textContainer: nil)
        textView.font = UIFont.clawline(.bodyText)
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 20, bottom: 12, right: 20)
        textView.text = attributedText.string

        coordinator.updateHeight(for: textView, allowAutoScroll: false)
        coordinator.updateHeight(for: textView, allowAutoScroll: false)
        coordinator.updateHeight(for: textView, allowAutoScroll: false)
        await Task.yield()

        #expect(textView.sizeThatFitsCallCount == 0)
        #expect(calculatedHeight == 44)

        textView.frame = CGRect(x: 0, y: 0, width: 240, height: 44)
        coordinator.updateHeight(for: textView, allowAutoScroll: false)

        #expect(textView.sizeThatFitsCallCount == 1)
        #expect(calculatedHeight > 44)
    }

    @Test("T1315 Return delegates to active mention picker instead of composer submit")
    @MainActor
    func returnDelegatesToMentionPickerInsteadOfSubmit() {
        var attributedText = NSAttributedString(string: "@des")
        var calculatedHeight: CGFloat = 44
        var selectionRange = NSRange(location: 4, length: 0)
        var pendingInsertions: [PendingAttachment] = []
        var submitCount = 0
        var mentionAcceptCount = 0
        let editor = RichTextEditor(
            attributedText: Binding(get: { attributedText }, set: { attributedText = $0 }),
            calculatedHeight: Binding(get: { calculatedHeight }, set: { calculatedHeight = $0 }),
            selectionRange: Binding(get: { selectionRange }, set: { selectionRange = $0 }),
            pendingInsertions: Binding(get: { pendingInsertions }, set: { pendingInsertions = $0 }),
            fontScaleChangeSequence: 0,
            resetToken: 0,
            focusTrigger: 0,
            dismissTrigger: 0,
            isEditable: true,
            isKeyboardVisible: true,
            tintColor: .systemBlue,
            onFocusChange: { _ in },
            onSubmit: { submitCount += 1 },
            handlesMentionPickerKeyCommands: true,
            mentionPickerHasCompletion: true,
            onMentionPickerTab: { mentionAcceptCount += 1 },
            keyboardOwnershipStore: KeyboardOwnershipSceneFactory.chatScene(
                visibleNotificationSourceChatIds: [],
                mentionPickerVisible: true,
                mentionPickerHasCompletion: true,
                composerFocused: true,
                notificationReplyFocusedSourceChatId: nil,
                actionMenuSourceChatId: nil
            )
        )
        let coordinator = RichTextEditor.Coordinator(parent: editor)
        let textView = UITextView()
        textView.text = "@des"

        let shouldChange = coordinator.textView(
            textView,
            shouldChangeTextIn: NSRange(location: 4, length: 0),
            replacementText: "\n"
        )

        #expect(!shouldChange)
        #expect(mentionAcceptCount == 1)
        #expect(submitCount == 0)
        #expect(textView.text == "@des")
    }

    @Test("T1315 Return submits composer when mention picker has no completion")
    @MainActor
    func returnSubmitsComposerWhenMentionPickerHasNoCompletion() {
        var attributedText = NSAttributedString(string: "@")
        var calculatedHeight: CGFloat = 44
        var selectionRange = NSRange(location: 1, length: 0)
        var pendingInsertions: [PendingAttachment] = []
        var submitCount = 0
        var mentionAcceptCount = 0
        let editor = RichTextEditor(
            attributedText: Binding(get: { attributedText }, set: { attributedText = $0 }),
            calculatedHeight: Binding(get: { calculatedHeight }, set: { calculatedHeight = $0 }),
            selectionRange: Binding(get: { selectionRange }, set: { selectionRange = $0 }),
            pendingInsertions: Binding(get: { pendingInsertions }, set: { pendingInsertions = $0 }),
            fontScaleChangeSequence: 0,
            resetToken: 0,
            focusTrigger: 0,
            dismissTrigger: 0,
            isEditable: true,
            isKeyboardVisible: true,
            tintColor: .systemBlue,
            onFocusChange: { _ in },
            onSubmit: { submitCount += 1 },
            handlesMentionPickerKeyCommands: true,
            mentionPickerHasCompletion: false,
            onMentionPickerTab: { mentionAcceptCount += 1 },
            keyboardOwnershipStore: KeyboardOwnershipSceneFactory.chatScene(
                visibleNotificationSourceChatIds: [],
                mentionPickerVisible: true,
                mentionPickerHasCompletion: false,
                composerFocused: true,
                notificationReplyFocusedSourceChatId: nil,
                actionMenuSourceChatId: nil
            )
        )
        let coordinator = RichTextEditor.Coordinator(parent: editor)
        let textView = UITextView()
        textView.text = "@"

        let shouldChange = coordinator.textView(
            textView,
            shouldChangeTextIn: NSRange(location: 1, length: 0),
            replacementText: "\n"
        )

        #expect(!shouldChange)
        #expect(submitCount == 1)
        #expect(mentionAcceptCount == 0)
        #expect(textView.text == "@")
    }

    @Test("Light disabled send button keeps an off-white backing circle")
    func lightDisabledSendButtonKeepsBackingCircle() {
        let lightColor = MessageInputBar.disabledSendButtonBackingColor(colorScheme: .light)
        let darkColor = MessageInputBar.disabledSendButtonBackingColor(colorScheme: .dark)

        #expect(lightColor != nil)
        #expect(darkColor == nil)
    }

    @Test("Disabled send backing can be suppressed for transparent hosts")
    func disabledSendButtonBackingCanBeSuppressed() {
        let lightColor = MessageInputBar.disabledSendButtonBackingColor(
            colorScheme: .light,
            drawsDisabledBacking: false
        )

        #expect(lightColor == nil)
    }

    @Test("Send button backing uses the same soft blur in every state")
    func sendButtonBackingUsesSoftBlur() {
        #expect(MessageInputBar.sendButtonColoredBackingBlurRadius == 7)
    }

    @Test("Rendered input field cap matches the regular-layout text width cap")
    func renderedInputFieldCapMatchesRegularFieldWidth() {
        let textWidth = ChatFlowTheme.maxLineWidth(bodyFont: UIFont.clawline(.bodyText))
        let fieldCap = MessageInputBar.renderedInputFieldWidthCap(
            containerWidth: 1600,
            isCompact: false,
            bottomSafeAreaInset: 34,
            isFieldFocused: false
        )

        #expect(fieldCap == textWidth)
    }

    @Test("Rendered input field cap subtracts bar chrome from compact container width")
    func renderedInputFieldCapSubtractsCompactChrome() {
        let containerWidth: CGFloat = 430
        let expectedFieldWidth = containerWidth - MessageInputBar.chromeWidth(
            isCompact: true,
            bottomSafeAreaInset: 34,
            isFieldFocused: false
        )
        let fieldCap = MessageInputBar.renderedInputFieldWidthCap(
            containerWidth: containerWidth,
            isCompact: true,
            bottomSafeAreaInset: 34,
            isFieldFocused: false
        )

        #expect(fieldCap == expectedFieldWidth)
    }

    @Test("Notification layout host reports viewport width")
    func notificationLayoutHostReportsViewportWidth() {
        #expect(CrossChatNotificationGeometry.layoutHostWidth(
            maxContainerWidth: 393
        ) == CGFloat(393))
    }

    @Test("Notification layout host rejects negative viewport widths")
    func notificationLayoutHostRejectsNegativeViewportWidths() {
        #expect(CrossChatNotificationGeometry.layoutHostWidth(
            maxContainerWidth: -10
        ) == CGFloat(0))
    }

    @Test("Notification layout host ignores oversized motion envelope width")
    func notificationLayoutHostIgnoresOversizedMotionEnvelopeWidth() {
        let viewportWidth = CGFloat(393)
        let motionEnvelopeWidth = viewportWidth + 131 + 131 + 24

        #expect(motionEnvelopeWidth > viewportWidth)
        #expect(CrossChatNotificationGeometry.layoutHostWidth(
            maxContainerWidth: viewportWidth
        ) == viewportWidth)
    }

    @Test("T1185 Spatial notification overlay docks to native window width")
    func spatialNotificationOverlayDocksToNativeWindowWidth() {
        let hostWidth = CGFloat(720)
        let nativeWindowWidth = CGFloat(960)
        let resolvedWidth = CrossChatNotificationGeometry.spatialOverlayContainerWidth(
            containerWidth: hostWidth,
            nativeWindowWidth: nativeWindowWidth
        )

        #expect(resolvedWidth == nativeWindowWidth)
        #expect(CrossChatNotificationGeometry.spatialOverlayHorizontalCorrection(
            containerWidth: hostWidth,
            resolvedContainerWidth: resolvedWidth
        ) == 0)
    }

    @Test("T1185 Spatial notification window width tolerates key-window handoff")
    func spatialNotificationWindowWidthToleratesKeyWindowHandoff() {
        #expect(CrossChatNotificationGeometry.spatialNativeWindowWidth(
            keyWindowWidth: 960,
            firstWindowWidth: 720
        ) == 960)
        #expect(CrossChatNotificationGeometry.spatialNativeWindowWidth(
            keyWindowWidth: nil,
            firstWindowWidth: 960
        ) == 960)
    }

    @Test("T1185 Spatial notification overlay stays inside host without a wider native window")
    func spatialNotificationOverlayStaysInsideHostWithoutWiderNativeWindow() {
        let hostWidth = CGFloat(720)

        #expect(CrossChatNotificationGeometry.spatialOverlayContainerWidth(
            containerWidth: hostWidth,
            nativeWindowWidth: nil
        ) == hostWidth)
        #expect(CrossChatNotificationGeometry.spatialOverlayContainerWidth(
            containerWidth: hostWidth,
            nativeWindowWidth: 680
        ) == hostWidth)
        #expect(CrossChatNotificationGeometry.spatialOverlayHorizontalCorrection(
            containerWidth: hostWidth,
            resolvedContainerWidth: hostWidth
        ) == 0)
    }

    @Test("T1185 Spatial notification correction does not push wider overlay past trailing edge")
    func spatialNotificationCorrectionDoesNotPushWiderOverlayPastTrailingEdge() {
        let hostWidth = CGFloat(720)
        let resolvedWidth = CGFloat(960)

        #expect(CrossChatNotificationGeometry.spatialOverlayHorizontalCorrection(
            containerWidth: hostWidth,
            resolvedContainerWidth: resolvedWidth
        ) == 0)
    }

    @Test("Rotated compact notification overlay uses physical landscape width")
    func rotatedCompactNotificationOverlayUsesPhysicalLandscapeWidth() {
        let resolvedFromPortraitHost = CrossChatNotificationGeometry.nativeOverlayContainerWidth(
            containerWidth: 402,
            leadingSafeAreaInset: 0,
            trailingSafeAreaInset: 0,
            isCompactLandscape: true,
            nativeWindowWidth: 874
        )
        let resolvedFromSafeAreaHost = CrossChatNotificationGeometry.nativeOverlayContainerWidth(
            containerWidth: 750,
            leadingSafeAreaInset: 62,
            trailingSafeAreaInset: 62,
            isCompactLandscape: true,
            nativeWindowWidth: 874
        )

        #expect(resolvedFromPortraitHost == 874)
        #expect(resolvedFromSafeAreaHost == 874)
        #expect(CrossChatNotificationGeometry.trailingAnchoredOverlayCorrection(
            containerWidth: 402,
            resolvedContainerWidth: resolvedFromPortraitHost
        ) == 472)
        #expect(CrossChatNotificationGeometry.trailingAnchoredOverlayCorrection(
            containerWidth: 874,
            resolvedContainerWidth: 874
        ) == 0)
    }

    @Test("Rotated compact notification overlay does not collapse to window short side")
    func rotatedCompactNotificationOverlayDoesNotCollapseToWindowShortSide() throws {
        let chatViewPath = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Clawline/Views/Chat/ChatView.swift")
        let source = try String(contentsOf: chatViewPath, encoding: .utf8)

        #expect(!source.contains("min($0.width, $0.height)"))
    }

    @Test("T1185 Spatial notification stack uses resolved window width before capping")
    func spatialNotificationStackUsesResolvedWindowWidthBeforeCapping() {
        let resolvedWidth = CrossChatNotificationGeometry.spatialOverlayContainerWidth(
            containerWidth: 360,
            nativeWindowWidth: 720
        )
        let stackWidth = CrossChatNotificationGeometry.stackWidth(
            maxContainerWidth: resolvedWidth,
            normalTrailingMargin: 12,
            compactLeadingFitMargin: 0,
            maxStackWidth: 562.5,
            isCollapsed: false
        )

        #expect(stackWidth == CGFloat(562.5))
    }

    @Test("T1185 Spatial single notification shares stacked width behavior")
    func spatialSingleNotificationSharesStackedWidthBehavior() {
        #expect(CrossChatNotificationGeometry.bubbleFrameWidth(
            maxBubbleWidth: 562.5,
            visibleNotificationCount: 1,
            isSpatial: true
        ) == nil)
        #expect(CrossChatNotificationGeometry.bubbleFrameWidth(
            maxBubbleWidth: 562.5,
            visibleNotificationCount: 2,
            isSpatial: true
        ) == nil)
        #expect(CrossChatNotificationGeometry.bubbleFrameWidth(
            maxBubbleWidth: 562.5,
            visibleNotificationCount: 1,
            isSpatial: false
        ) == nil)
    }

    @Test("T1185 Spatial single notification max height is bounded by available dock height")
    func spatialSingleNotificationMaxHeightIsBoundedByAvailableDockHeight() {
        #expect(CrossChatNotificationGeometry.bubbleMaxHeight(
            isCompactLayout: false,
            maxContainerHeight: 240
        ) == CGFloat(240))
        #expect(CrossChatNotificationGeometry.bubbleMaxHeight(
            isCompactLayout: false,
            maxContainerHeight: 620
        ) == CrossChatNotificationGeometry.compactBubbleMaxHeight * 2)
    }

    @Test("T1185 notification capacity uses measured bubble heights")
    func notificationCapacityUsesMeasuredBubbleHeights() {
        #expect(CrossChatNotificationGeometry.visibleCapacity(
            maxContainerHeight: 240,
            bubbleHeights: [104, 104, 104],
            bubbleSpacing: 10,
            maxVisibleBubbleCount: 10
        ) == 2)
    }

    @Test("T1185 reply ordering uses measured notification capacity")
    func replyOrderingUsesMeasuredNotificationCapacity() throws {
        let chatViewPath = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Clawline/Views/Chat/ChatView.swift")
        let source = try String(contentsOf: chatViewPath, encoding: .utf8)

        #expect(source.contains("visibleCapacity: Self.visibleCapacity(\n                maxContainerHeight: maxContainerHeight,\n                bubbles: viewModel.crossChatNotificationBubbles,\n                measuredHeightsBySourceChatId: measuredBubbleHeightsBySourceChatId"))
        #expect(!source.contains("visibleCapacity: Self.visibleCapacity(maxContainerHeight: maxContainerHeight)"))
    }

    @Test("T1185 simulator render proof artifacts")
    @MainActor
    func simulatorRenderProofArtifacts() throws {
        let proofDirectory = try t1185ProofDirectory()
        let maxBubbleWidth = CGFloat(562.5)
        let singleWidth = CrossChatNotificationGeometry.bubbleFrameWidth(
            maxBubbleWidth: maxBubbleWidth,
            visibleNotificationCount: 1,
            isSpatial: true
        )
        #expect(singleWidth == nil)

        let measuredCapacity = CrossChatNotificationGeometry.visibleCapacity(
            maxContainerHeight: 330,
            bubbleHeights: [160, 160, 160],
            bubbleSpacing: 10,
            maxVisibleBubbleCount: 10
        )
        #expect(measuredCapacity == 2)

        let singleImage = renderT1185ProofImage(
            T1185ProofBackdrop {
                t1185NotificationBubble(
                    id: "t1185-single",
                    title: "Flynn Spatial",
                    content: "Single Spatial notification containment proof: this card should sit inside the host with rounded standard visionOS glass.",
                    assignedNumber: 1,
                    visibleNotificationCount: 1,
                    maxBubbleWidth: maxBubbleWidth,
                    maxBubbleHeight: 220
                )
            },
            size: CGSize(width: 720, height: 300)
        )
        try writeT1185ProofImage(singleImage, name: "t1185-single-containment-glass.png", directory: proofDirectory)

        let stackedImage = renderT1185ProofImage(
            T1185ProofBackdrop {
                VStack(alignment: .trailing, spacing: 10) {
                    t1185NotificationBubble(
                        id: "t1185-stack-1",
                        title: "Spatial Stack A",
                        content: "First stacked notification remains on the shared card geometry.",
                        assignedNumber: 1,
                        visibleNotificationCount: 2,
                        maxBubbleWidth: maxBubbleWidth,
                        maxBubbleHeight: 180
                    )
                    t1185NotificationBubble(
                        id: "t1185-stack-2",
                        title: "Spatial Stack B",
                        content: "Second stacked notification preserves spacing, width, and glass treatment.",
                        assignedNumber: 2,
                        visibleNotificationCount: 2,
                        maxBubbleWidth: maxBubbleWidth,
                        maxBubbleHeight: 180
                    )
                }
            },
            size: CGSize(width: 720, height: 430)
        )
        try writeT1185ProofImage(stackedImage, name: "t1185-stacked-preservation-glass.png", directory: proofDirectory)

        let capacityImage = renderT1185ProofImage(
            T1185ProofBackdrop {
                VStack(alignment: .trailing, spacing: 10) {
                    ForEach(0..<measuredCapacity, id: \.self) { index in
                        t1185NotificationBubble(
                            id: "t1185-capacity-\(index)",
                            title: "Measured Capacity \(index + 1)",
                            content: "Measured height capacity proof renders only the two cards that fit inside the 330 point capacity budget.",
                            assignedNumber: index + 1,
                            visibleNotificationCount: measuredCapacity,
                            maxBubbleWidth: maxBubbleWidth,
                            maxBubbleHeight: 160
                        )
                    }
                }
            },
            size: CGSize(width: 720, height: 430)
        )
        try writeT1185ProofImage(capacityImage, name: "t1185-measured-capacity-two-visible-glass.png", directory: proofDirectory)

        let metadata = """
        {
          "ticket": "T1185",
          "singleSpatialBubbleFrameWidth": "\(String(describing: singleWidth))",
          "measuredCapacityForThree160PointBubblesIn330PointContainer": \(measuredCapacity),
          "artifacts": [
            "t1185-single-containment-glass.png",
            "t1185-stacked-preservation-glass.png",
            "t1185-measured-capacity-two-visible-glass.png"
          ]
        }
        """
        try metadata.write(
            to: proofDirectory.appendingPathComponent("t1185-render-proof-metadata.json"),
            atomically: true,
            encoding: .utf8
        )
    }

    @Test("T354 notification layout host height excludes motion overflow")
    func notificationLayoutHostHeightExcludesMotionOverflow() {
        let topMargin = CGFloat(8)
        let availableHeightAboveComposer = CGFloat(620)
        let motionEnvelopeHeight = topMargin + availableHeightAboveComposer + 131 + 12
        let layoutHostHeight = CrossChatNotificationGeometry.layoutHostHeight(
            topMargin: topMargin,
            maxContainerHeight: availableHeightAboveComposer
        )

        #expect(motionEnvelopeHeight > layoutHostHeight)
        #expect(layoutHostHeight == topMargin + availableHeightAboveComposer + 12)
    }

    @Test("Spatial notification layout host includes motion overflow")
    func spatialNotificationLayoutHostIncludesMotionOverflow() {
        let topMargin = CGFloat(8)
        let availableHeightAboveComposer = CGFloat(620)
        let standardHostHeight = CrossChatNotificationGeometry.layoutHostHeight(
            topMargin: topMargin,
            maxContainerHeight: availableHeightAboveComposer
        )
        let spatialHostHeight = CrossChatNotificationGeometry.spatialLayoutHostHeight(
            topMargin: topMargin,
            maxContainerHeight: availableHeightAboveComposer
        )

        #expect(spatialHostHeight > standardHostHeight)
    }

    @Test("T354 notification short content does not add blank bottom tail")
    func notificationShortContentDoesNotAddBlankBottomTail() {
        let measuredContentHeight = CGFloat(52)
        let contentMaxHeight = CGFloat(104)
        let entriesNeedScroll = CrossChatNotificationEntrySurfaceGeometry.entriesNeedScroll(
            measuredContentHeight: measuredContentHeight,
            contentMaxHeight: contentMaxHeight
        )

        #expect(!entriesNeedScroll)
        #expect(CrossChatNotificationEntrySurfaceGeometry.resolvedViewportHeight(
            measuredContentHeight: measuredContentHeight,
            contentMaxHeight: contentMaxHeight,
            entriesNeedScroll: entriesNeedScroll
        ) == nil)
        #expect(CrossChatNotificationEntrySurfaceGeometry.bottomBreathingRoom(
            entriesNeedScroll: entriesNeedScroll,
            configuredBreathingRoom: 8
        ) == CGFloat(0))
    }

    @Test("T354 notification scroll content keeps internal bottom breathing room")
    func notificationScrollableContentKeepsInternalBottomBreathingRoom() {
        let measuredContentHeight = CGFloat(180)
        let contentMaxHeight = CGFloat(104)
        let entriesNeedScroll = CrossChatNotificationEntrySurfaceGeometry.entriesNeedScroll(
            measuredContentHeight: measuredContentHeight,
            contentMaxHeight: contentMaxHeight
        )

        #expect(entriesNeedScroll)
        #expect(CrossChatNotificationEntrySurfaceGeometry.resolvedViewportHeight(
            measuredContentHeight: measuredContentHeight,
            contentMaxHeight: contentMaxHeight,
            entriesNeedScroll: entriesNeedScroll
        ) == contentMaxHeight)
        #expect(CrossChatNotificationEntrySurfaceGeometry.bottomBreathingRoom(
            entriesNeedScroll: entriesNeedScroll,
            configuredBreathingRoom: 8
        ) == CGFloat(8))
    }

    @Test("Notification reply row preserves send tap target on narrow phone width")
    func notificationReplyRowPreservesSendTapTargetOnNarrowPhoneWidth() {
        let stackWidth = CrossChatNotificationGeometry.stackWidth(
            maxContainerWidth: 320,
            normalTrailingMargin: 6,
            compactLeadingFitMargin: 24,
            maxStackWidth: 562.5,
            isCollapsed: false
        )
        let inputWidth = CrossChatNotificationGeometry.replyInputAvailableWidth(
            stackWidth: stackWidth,
            leadingPadding: 24,
            trailingPadding: 12,
            sendControlWidth: 44,
            replyControlSpacing: 8
        )

        #expect(stackWidth == CGFloat(290))
        #expect(inputWidth == CGFloat(202))
    }

    @Test("Notification reply row keeps send tap target when collapsed")
    func notificationReplyRowKeepsSendTapTargetWhenCollapsed() {
        let stackWidth = CrossChatNotificationGeometry.stackWidth(
            maxContainerWidth: 320,
            normalTrailingMargin: 6,
            compactLeadingFitMargin: 24,
            maxStackWidth: 562.5,
            isCollapsed: true
        )
        let inputWidth = CrossChatNotificationGeometry.replyInputAvailableWidth(
            stackWidth: stackWidth,
            leadingPadding: 24,
            trailingPadding: 12,
            sendControlWidth: 44,
            replyControlSpacing: 8
        )

        #expect(stackWidth == CGFloat(320))
        #expect(inputWidth == CGFloat(232))
    }

    @Test("Notification layout host keeps Ansible landscape safe area out of root width")
    func notificationLayoutHostKeepsAnsibleLandscapeSafeAreaOutOfRootWidth() {
        let viewportWidth = CGFloat(852)
        let stackWidth = CGFloat(562.5)
        let peekWidth = CGFloat(18)

        #expect(CrossChatNotificationGeometry.layoutHostWidth(
            maxContainerWidth: viewportWidth
        ) == viewportWidth)
        #expect(CrossChatNotificationGeometry.collapsedOffset(
            stackWidth: stackWidth,
            collapsedPeekWidth: peekWidth,
            trailingSafeAreaInset: 0
        ) == stackWidth - peekWidth)
    }

    @Test("T357 transcript collection frame fills compact landscape window from safe-area host")
    func transcriptCollectionFrameFillsCompactLandscapeWindowFromSafeAreaHost() {
        let targetFrame = MessageFlowCollectionViewController.targetCollectionFrame(
            viewBounds: CGRect(x: 0, y: 0, width: 750, height: 402),
            windowBounds: CGRect(x: 0, y: 0, width: 874, height: 402),
            viewOriginInWindow: CGPoint(x: 62, y: 0),
            fillsHorizontallyConstrainedHostToWindow: true
        )

        #expect(targetFrame == CGRect(x: -62, y: 0, width: 874, height: 402))
    }

    @Test("T357 transcript collection frame preserves constrained host outside compact landscape fill")
    func transcriptCollectionFramePreservesConstrainedHostOutsideCompactLandscapeFill() {
        let targetFrame = MessageFlowCollectionViewController.targetCollectionFrame(
            viewBounds: CGRect(x: 0, y: 0, width: 750, height: 402),
            windowBounds: CGRect(x: 0, y: 0, width: 874, height: 402),
            viewOriginInWindow: CGPoint(x: 62, y: 0)
        )

        #expect(targetFrame == CGRect(x: 0, y: 0, width: 750, height: 402))
    }

    @Test("T357 transcript collection frame preserves full-window width when host is unconstrained")
    func transcriptCollectionFramePreservesFullWindowWidthWhenHostIsUnconstrained() {
        let targetFrame = MessageFlowCollectionViewController.targetCollectionFrame(
            viewBounds: CGRect(x: 0, y: 0, width: 874, height: 402),
            windowBounds: CGRect(x: 0, y: 0, width: 874, height: 402),
            viewOriginInWindow: CGPoint(x: 0, y: 0)
        )

        #expect(targetFrame == CGRect(x: 0, y: 0, width: 874, height: 402))
    }

    @Test("T357 Catalyst frame calculation preserves historical full-window width")
    func catalystFrameCalculationPreservesHistoricalFullWindowWidth() {
        let targetFrame = MessageFlowCollectionViewController.targetCollectionFrame(
            viewBounds: CGRect(x: 0, y: 0, width: 750, height: 402),
            windowBounds: CGRect(x: 0, y: 0, width: 874, height: 402),
            viewOriginInWindow: CGPoint(x: 62, y: 0),
            preservesHorizontallyConstrainedHostWidth: false
        )

        #expect(targetFrame == CGRect(x: 0, y: 0, width: 874, height: 402))
    }

    @Test("T357 compact landscape pinned chrome uses physical width")
    func compactLandscapePinnedChromeUsesPhysicalWidth() {
        #expect(ChatLandscapeWidthGeometry.shouldFillWindowWidth(
            viewSize: CGSize(width: 750, height: 402),
            windowSize: CGSize(width: 874, height: 402),
            isCompactLandscape: true
        ))
        #expect(ChatLandscapeWidthGeometry.physicalWidth(
            containerWidth: 750,
            leadingSafeAreaInset: 62,
            trailingSafeAreaInset: 62,
            isCompactLandscape: true
        ) == 874)
        #expect(ChatLandscapeWidthGeometry.horizontalOffset(
            leadingSafeAreaInset: 62,
            trailingSafeAreaInset: 62,
            isCompactLandscape: true
        ) == 0)
    }

    @Test("T357 compact landscape message surface uses physical width")
    func compactLandscapeMessageSurfaceUsesPhysicalWidth() {
        #expect(ChatLandscapeWidthGeometry.physicalWidth(
            containerWidth: 750,
            leadingSafeAreaInset: 62,
            trailingSafeAreaInset: 62,
            isCompactLandscape: true
        ) == 874)
        #expect(ChatLandscapeWidthGeometry.physicalWidth(
            containerWidth: 402,
            leadingSafeAreaInset: 0,
            trailingSafeAreaInset: 0,
            isCompactLandscape: true,
            nativeWindowWidth: 874
        ) == 874)
        #expect(ChatLandscapeWidthGeometry.horizontalOffset(
            containerWidth: 402,
            leadingSafeAreaInset: 0,
            trailingSafeAreaInset: 0,
            isCompactLandscape: true,
            nativeWindowWidth: 874
        ) == 236)
        #expect(ChatLandscapeWidthGeometry.shouldFillWindowWidth(
            viewSize: CGSize(width: 402, height: 874),
            windowSize: CGSize(width: 874, height: 402),
            isCompactLandscape: true
        ))
    }

    @Test("T1282 compact landscape recovers physical width from rotated portrait window size")
    func compactLandscapeRecoversPhysicalWidthFromRotatedPortraitWindowSize() {
        let physicalWidth = ChatLandscapeWidthGeometry.physicalWindowWidth(
            from: CGSize(width: 402, height: 874)
        )

        #expect(physicalWidth == 874)
        #expect(ChatLandscapeWidthGeometry.physicalWidth(
            containerWidth: 750,
            leadingSafeAreaInset: 0,
            trailingSafeAreaInset: 0,
            isCompactLandscape: true,
            nativeWindowWidth: physicalWidth
        ) == 874)
        #expect(ChatLandscapeWidthGeometry.horizontalOffset(
            containerWidth: 750,
            leadingSafeAreaInset: 0,
            trailingSafeAreaInset: 0,
            isCompactLandscape: true,
            nativeWindowWidth: physicalWidth
        ) == 62)
    }

    @Test("T357 asymmetric compact landscape chrome recenters to physical window")
    func asymmetricCompactLandscapeChromeRecentersToPhysicalWindow() {
        #expect(ChatLandscapeWidthGeometry.physicalWidth(
            containerWidth: 750,
            leadingSafeAreaInset: 44,
            trailingSafeAreaInset: 80,
            isCompactLandscape: true
        ) == 874)
        #expect(ChatLandscapeWidthGeometry.horizontalOffset(
            leadingSafeAreaInset: 44,
            trailingSafeAreaInset: 80,
            isCompactLandscape: true
        ) == 18)
        #expect(ChatLandscapeWidthGeometry.horizontalOffset(
            containerWidth: 750,
            leadingSafeAreaInset: 44,
            trailingSafeAreaInset: 80,
            isCompactLandscape: true,
            nativeWindowWidth: 800
        ) == 18)
    }

    @Test("T357 docked landscape notification reserves trailing transcript clearance")
    func dockedLandscapeNotificationReservesTrailingTranscriptClearance() {
        let clearance = CrossChatNotificationGeometry.transcriptTrailingClearance(
            isCompactLandscape: true,
            isNotificationDocked: true,
            visibleNotificationCount: 1
        )
        let insets = MessageFlowCollectionViewController.flowSectionInset(
            containerPadding: 12,
            trailingContentInset: clearance
        )

        #expect(clearance == CrossChatNotificationGeometry.collapsedPeekWidth)
        #expect(insets == UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 30))
    }

    @Test("T357 transcript clearance is inactive outside docked compact landscape")
    func transcriptClearanceIsInactiveOutsideDockedCompactLandscape() {
        #expect(CrossChatNotificationGeometry.transcriptTrailingClearance(
            isCompactLandscape: false,
            isNotificationDocked: true,
            visibleNotificationCount: 1
        ) == 0)
        #expect(CrossChatNotificationGeometry.transcriptTrailingClearance(
            isCompactLandscape: true,
            isNotificationDocked: false,
            visibleNotificationCount: 1
        ) == 0)
        #expect(CrossChatNotificationGeometry.transcriptTrailingClearance(
            isCompactLandscape: true,
            isNotificationDocked: true,
            visibleNotificationCount: 0
        ) == 0)
    }

    @Test("T357 transcript notification clearance is scoped to native iOS")
    func transcriptNotificationClearanceIsScopedToNativeIOS() throws {
        let chatViewPath = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Clawline/Views/Chat/ChatView.swift")
        let source = try String(contentsOf: chatViewPath, encoding: .utf8)
        let pattern = #"#if os\(iOS\) && !targetEnvironment\(macCatalyst\)[\s\S]*?transcriptTrailingClearance\([\s\S]*?#else[\s\S]*?return 0[\s\S]*?#endif"#
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        let regex = try NSRegularExpression(pattern: pattern)

        #expect(regex.firstMatch(in: source, range: range) != nil)
    }

    @Test("Notification collapsed offset preserves portrait peek with no trailing inset")
    func notificationCollapsedOffsetPreservesPortraitPeekWithNoTrailingInset() {
        let stackWidth = CGFloat(361)
        let peekWidth = CGFloat(18)

        #expect(CrossChatNotificationGeometry.collapsedOffset(
            stackWidth: stackWidth,
            collapsedPeekWidth: peekWidth,
            trailingSafeAreaInset: 0
        ) == stackWidth - peekWidth)
    }

    @Test("Notification collapsed offset compensates compact landscape safe-area gutter")
    func notificationCollapsedOffsetCompensatesCompactLandscapeSafeAreaGutter() {
        let stackWidth = CGFloat(562.5)
        let peekWidth = CGFloat(18)
        let landscapeTrailingSafeArea = CGFloat(47)

        #expect(CrossChatNotificationGeometry.collapsedOffset(
            stackWidth: stackWidth,
            collapsedPeekWidth: peekWidth,
            trailingSafeAreaInset: landscapeTrailingSafeArea
        ) == stackWidth - peekWidth + landscapeTrailingSafeArea)
    }

    @Test("Notification collapsed offset keeps iPad zero-inset landscape behavior")
    func notificationCollapsedOffsetKeepsIPadZeroInsetLandscapeBehavior() {
        let stackWidth = CGFloat(562.5)
        let peekWidth = CGFloat(18)

        #expect(CrossChatNotificationGeometry.collapsedOffset(
            stackWidth: stackWidth,
            collapsedPeekWidth: peekWidth,
            trailingSafeAreaInset: 0
        ) == stackWidth - peekWidth)
    }
}

private final class HeightProbeTextView: UITextView {
    private(set) var sizeThatFitsCallCount = 0

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        sizeThatFitsCallCount += 1
        return super.sizeThatFits(size)
    }
}

private struct T1185ProofBackdrop<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ZStack(alignment: .topTrailing) {
            checkerboard
            content
                .padding(.top, 28)
                .padding(.trailing, 48)
        }
    }

    private var checkerboard: some View {
        Canvas { context, size in
            let cell = CGFloat(36)
            for row in 0..<Int(ceil(size.height / cell)) {
                for column in 0..<Int(ceil(size.width / cell)) {
                    let isAlternate = (row + column).isMultiple(of: 2)
                    let color = isAlternate
                        ? Color(red: 0.12, green: 0.20, blue: 0.34)
                        : Color(red: 0.82, green: 0.88, blue: 0.95)
                    context.fill(
                        Path(CGRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell, width: cell, height: cell)),
                        with: .color(color)
                    )
                }
            }
        }
    }
}

@MainActor
private func t1185NotificationBubble(
    id: String,
    title: String,
    content: String,
    assignedNumber: Int,
    visibleNotificationCount: Int,
    maxBubbleWidth: CGFloat,
    maxBubbleHeight: CGFloat
) -> some View {
    CrossChatNotificationBubbleView(
        bubble: CrossChatNotificationBubble(
            sourceChatId: id,
            sourceTitle: title,
            entries: [
                CrossChatAssistantNotificationEntry(
                    id: "\(id)-entry",
                    content: content,
                    timestamp: Date()
                )
            ],
            lastAssistantActivityAt: Date()
        ),
        assignedNumber: assignedNumber,
        visibleNotificationCount: visibleNotificationCount,
        showShortcutLabel: true,
        isShortcutLabelDisabled: false,
        maxBubbleHeight: maxBubbleHeight,
        maxBubbleWidth: maxBubbleWidth,
        bubbleCornerRadius: 18,
        isSending: false,
        canCancelSend: false,
        canSendReply: false,
        connectionState: .connected,
        replyDraft: .constant(""),
        onDismiss: {},
        onReply: {},
        onCancelReply: {},
        onDismissAll: {},
        onNavigate: {},
        onSendReply: {},
        onCancelSend: {},
        onReconnect: {},
        onActivate: {},
        onReplyFocusChange: { _ in },
        isActionMenuOpen: false,
        actionMenuSelection: .goToChat,
        onActionMenuSelectionChange: { _ in },
        onActionMenuAction: { _ in },
        onRegisterScrollView: { _ in },
        isDismissSwipeActive: false,
        isContentScrollLocked: false,
        onContentScrollDragChanged: { _ in },
        onContentScrollDragEnded: {},
        onTextSelectionChange: { _ in }
    )
}

@MainActor
private func renderT1185ProofImage<Content: View>(_ view: Content, size: CGSize) -> UIImage {
    let host = UIHostingController(rootView: view.frame(width: size.width, height: size.height))
    host.view.frame = CGRect(origin: .zero, size: size)
    host.view.backgroundColor = .clear
    host.view.setNeedsLayout()
    host.view.layoutIfNeeded()

    let renderer = UIGraphicsImageRenderer(size: size)
    return renderer.image { _ in
        host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
    }
}

private func t1185ProofDirectory() throws -> URL {
    let environment = ProcessInfo.processInfo.environment
    let directoryPath = environment["T1185_RENDER_PROOF_DIR"]
        ?? environment["TEST_RUNNER_T1185_RENDER_PROOF_DIR"]
        ?? "scratch/t1185-render-proof"
    let directory = URL(fileURLWithPath: directoryPath, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func writeT1185ProofImage(_ image: UIImage, name: String, directory: URL) throws {
    let url = directory.appendingPathComponent(name)
    let data = try #require(image.pngData())
    try data.write(to: url, options: .atomic)
    #expect(data.count > 1_000)
}
