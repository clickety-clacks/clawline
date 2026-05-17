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
}
