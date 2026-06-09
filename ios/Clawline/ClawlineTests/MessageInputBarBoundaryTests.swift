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
        ) == nativeWindowWidth - hostWidth)
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

    @Test("T1185 Spatial single notification occupies resolved stack width")
    func spatialSingleNotificationOccupiesResolvedStackWidth() {
        #expect(CrossChatNotificationGeometry.bubbleFrameWidth(
            maxBubbleWidth: 562.5,
            visibleNotificationCount: 1,
            isSpatial: true
        ) == CGFloat(562.5))
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
    func compactLandscapeMessageSurfaceUsesPhysicalWidth() throws {
        let chatViewPath = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Clawline/Views/Chat/ChatView.swift")
        let source = try String(contentsOf: chatViewPath, encoding: .utf8)

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
        #expect(source.contains(".frame(width: chatSurfaceWidth)"))
        #expect(source.contains(".offset(x: chatSurfaceOffset)"))
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
