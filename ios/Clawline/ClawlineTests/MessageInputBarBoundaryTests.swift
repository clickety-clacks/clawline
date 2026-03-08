//
//  MessageInputBarBoundaryTests.swift
//  ClawlineTests
//
//  Created by Codex on 3/4/26.
//

import Testing
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
            isPreparing: false,
            connectionState: .connected
        )
        let activeState = MessageInputBar.sendButtonBubbleVisualState(
            isSending: false,
            canSend: true,
            isPreparing: false,
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
                isPreparing: true,
                connectionState: .connected
            )
        )
        #expect(
            MessageInputBar.sendButtonBubbleVisualState(
                isSending: false,
                canSend: false,
                isPreparing: true,
                connectionState: .connected
            ) == .active
        )
        #expect(
            !MessageInputBar.sendButtonShowsPreparingSpinner(
                isSending: false,
                canSend: false,
                isPreparing: true,
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
                isPreparing: false,
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
}
