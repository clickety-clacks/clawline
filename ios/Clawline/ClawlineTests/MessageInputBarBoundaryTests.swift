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
