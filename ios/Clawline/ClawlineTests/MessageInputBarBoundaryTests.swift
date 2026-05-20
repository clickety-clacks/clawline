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

    @Test("Reconnect bubble keeps the 0.75 small-end scale")
    func reconnectBubbleRetainsRequestedSmallEndScale() {
        #expect(MessageInputBar.reconnectBubbleScale(phase: CGFloat(0)) == CGFloat(0.75))
        #expect(MessageInputBar.reconnectBubbleScale(phase: CGFloat(1)) == CGFloat(1.0))
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
