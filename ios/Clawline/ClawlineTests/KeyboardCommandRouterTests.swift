//
//  KeyboardCommandRouterTests.swift
//  ClawlineTests
//
//  Created by Codex on 5/19/26.
//

import Testing
import SwiftUI
import UIKit
@testable import Clawline

@MainActor
struct KeyboardCommandRouterTests {
    @Test("T343 VG-01 bridge normalization maps physical shortcuts to semantic intents")
    func bridgeNormalizationMapsPhysicalShortcutsToSemanticIntents() {
        #expect(KeyboardCommandBridge.intent(input: "j", modifierFlags: [.command]) == .transcriptBubbleScrollForward)
        #expect(KeyboardCommandBridge.intent(input: "j", modifierFlags: [.command, .shift]) == .transcriptChatScrollForward)
        #expect(KeyboardCommandBridge.intent(input: "3", modifierFlags: [.command]) == .notificationAssignedOpen(3))
        #expect(KeyboardCommandBridge.intent(input: "#", modifierFlags: [.command, .shift]) == .notificationAssignedReply(3))
        #expect(KeyboardCommandBridge.intent(input: "#", modifierFlags: [.command, .shift, .alternate]) == .notificationAssignedDismiss(3))
        #expect(KeyboardCommandBridge.intent(input: "-", modifierFlags: [.command]) == .notificationDismissAll)
        #expect(KeyboardCommandBridge.intent(input: "\\", modifierFlags: [.command]) == .notificationToggleDock)
        #expect(KeyboardCommandBridge.intent(input: "/", modifierFlags: [.command]) == .openStreamPopup)
        #expect(KeyboardCommandBridge.intent(input: "\r", modifierFlags: [.control]) == .textModifiedNewline)
        #expect(KeyboardCommandBridge.intent(input: UIKeyCommand.inputUpArrow, modifierFlags: []) == .menuNavigateUp)
        #expect(KeyboardCommandBridge.intent(input: "\t", modifierFlags: []) == .pickerAccept)
    }

    @Test("T343 VG-02 router priority matrix chooses one owner for conflicting states")
    func routerPriorityMatrixChoosesOneOwnerForConflictingStates() {
        let store = KeyboardOwnershipSceneFactory.chatScene(
            visibleNotificationSourceChatIds: ["n0", "n1"],
            mentionPickerVisible: true,
            mentionPickerHasCompletion: true,
            composerFocused: true,
            notificationReplySourceChatIds: ["n0"],
            notificationReplyFocusedSourceChatId: "n0",
            actionMenuSourceChatId: "n1"
        )

        assertRoute(.menuNavigateDown, in: store, isHandledBy: .notificationActionMenu("n1"), rule: "PR-01")
        assertRoute(.pickerNavigateUp, in: store, isHandledBy: .mentionPicker, rule: "PR-02")
        assertRoute(.notificationAssignedReply(1), in: store, isHandledBy: .notificationBubble("n1"), rule: "PR-03")
        assertRoute(.notificationDismissAll, in: store, isHandledBy: .notificationBubble("n0"), rule: "PR-04")
        assertRoute(.notificationScrollForward, in: store, isHandledBy: .notificationBubble("n0"), rule: "PR-04")
        assertRoute(.textSubmit, in: store, isHandledBy: .mentionPicker, rule: "PR-02")
        assertRoute(.textModifiedNewline, in: store, isHandledBy: .notificationReply("n0"), rule: "PR-05")
    }

    @Test("T343 VG-03 mention picker open close cannot poison notification scroll ownership")
    func mentionPickerOpenCloseCannotPoisonNotificationScrollOwnership() {
        let openStore = KeyboardOwnershipSceneFactory.chatScene(
            visibleNotificationSourceChatIds: ["n0"],
            mentionPickerVisible: true,
            mentionPickerHasCompletion: true,
            composerFocused: true,
            notificationReplyFocusedSourceChatId: nil,
            actionMenuSourceChatId: nil
        )
        let closedStore = KeyboardOwnershipSceneFactory.chatScene(
            visibleNotificationSourceChatIds: ["n0"],
            mentionPickerVisible: false,
            composerFocused: true,
            notificationReplyFocusedSourceChatId: nil,
            actionMenuSourceChatId: nil
        )

        assertRoute(.pickerNavigateDown, in: openStore, isHandledBy: .mentionPicker, rule: "PR-02")
        assertRoute(.notificationScrollForward, in: openStore, isHandledBy: .notificationBubble("n0"), rule: "PR-04")
        #expect(KeyboardCommandRouter.route(intent: .pickerNavigateDown, store: closedStore).outcome == .fallthroughToDefault)
        assertRoute(.notificationScrollForward, in: closedStore, isHandledBy: .notificationBubble("n0"), rule: "PR-04")
    }

    @Test("T343 VG-03 mention picker without completions does not own Return")
    func mentionPickerWithoutCompletionsDoesNotOwnReturn() {
        let store = KeyboardOwnershipSceneFactory.chatScene(
            visibleNotificationSourceChatIds: [],
            mentionPickerVisible: true,
            mentionPickerHasCompletion: false,
            composerFocused: true,
            notificationReplyFocusedSourceChatId: nil,
            actionMenuSourceChatId: nil
        )

        assertRoute(.pickerNavigateDown, in: store, isHandledBy: .mentionPicker, rule: "PR-02")
        #expect(KeyboardCommandRouter.route(intent: .pickerAccept, store: store).outcome == .fallthroughToDefault)
        assertRoute(.textSubmit, in: store, isHandledBy: .composer, rule: "PR-06")
    }

    @Test("T343 VG-03 parent teardown revokes action menu and reply child ownership")
    func parentTeardownRevokesActionMenuAndReplyChildOwnership() {
        var store = KeyboardOwnershipSceneFactory.chatScene(
            visibleNotificationSourceChatIds: ["n0"],
            mentionPickerVisible: false,
            composerFocused: false,
            notificationReplySourceChatIds: ["n0"],
            notificationReplyFocusedSourceChatId: "n0",
            actionMenuSourceChatId: "n0"
        )

        assertRoute(.menuActivate, in: store, isHandledBy: .notificationActionMenu("n0"), rule: "PR-01")
        assertRoute(.textCancel, in: store, isHandledBy: .notificationReply("n0"), rule: "PR-05")

        store.unregister(
            surfaceId: .notificationBubble("n0"),
            lifecycleToken: "notification-bubble:n0"
        )

        #expect(store.surfaceRegistry[.notificationActionMenu("n0")] == nil)
        #expect(store.surfaceRegistry[.notificationReply("n0")] == nil)
        #expect(KeyboardCommandRouter.route(intent: .menuActivate, store: store).outcome == .fallthroughToDefault)
        #expect(KeyboardCommandRouter.route(intent: .textCancel, store: store).outcome == .fallthroughToDefault)
    }

    @Test("T343 VG-03 reply close revokes stale focused reply ownership")
    func replyCloseRevokesStaleFocusedReplyOwnership() {
        let openStore = KeyboardOwnershipSceneFactory.chatScene(
            visibleNotificationSourceChatIds: ["n0"],
            mentionPickerVisible: false,
            composerFocused: true,
            notificationReplySourceChatIds: ["n0"],
            notificationReplyFocusedSourceChatId: "n0",
            actionMenuSourceChatId: nil
        )
        let closedStore = KeyboardOwnershipSceneFactory.chatScene(
            visibleNotificationSourceChatIds: ["n0"],
            mentionPickerVisible: false,
            composerFocused: true,
            notificationReplySourceChatIds: [],
            notificationReplyFocusedSourceChatId: "n0",
            actionMenuSourceChatId: nil
        )

        assertRoute(.textSubmit, in: openStore, isHandledBy: .notificationReply("n0"), rule: "PR-05")
        assertRoute(.textSubmit, in: closedStore, isHandledBy: .composer, rule: "PR-06")
    }

    @Test("T343 VG-04 notification visibility and text focus route scroll and return correctly")
    func notificationVisibilityAndTextFocusRouteScrollAndReturnCorrectly() {
        let composerOnly = KeyboardOwnershipSceneFactory.chatScene(
            visibleNotificationSourceChatIds: [],
            mentionPickerVisible: false,
            composerFocused: true,
            notificationReplyFocusedSourceChatId: nil,
            actionMenuSourceChatId: nil
        )
        let replyWithNotification = KeyboardOwnershipSceneFactory.chatScene(
            visibleNotificationSourceChatIds: ["n0"],
            mentionPickerVisible: false,
            composerFocused: false,
            notificationReplySourceChatIds: ["n0"],
            notificationReplyFocusedSourceChatId: "n0",
            actionMenuSourceChatId: nil
        )
        let transcriptOnly = KeyboardOwnershipSceneFactory.chatScene(
            visibleNotificationSourceChatIds: [],
            mentionPickerVisible: false,
            composerFocused: false,
            notificationReplyFocusedSourceChatId: nil,
            actionMenuSourceChatId: nil
        )

        assertRoute(.textSubmit, in: composerOnly, isHandledBy: .composer, rule: "PR-06")
        assertRoute(.textModifiedNewline, in: composerOnly, isHandledBy: .composer, rule: "PR-06")
        assertRoute(.notificationScrollBackward, in: replyWithNotification, isHandledBy: .notificationBubble("n0"), rule: "PR-04")
        assertRoute(.textSubmit, in: replyWithNotification, isHandledBy: .notificationReply("n0"), rule: "PR-05")
        assertRoute(.textModifiedNewline, in: replyWithNotification, isHandledBy: .notificationReply("n0"), rule: "PR-05")
        assertRoute(.transcriptChatScrollForward, in: transcriptOnly, isHandledBy: .transcript, rule: "PR-07")
        #expect(KeyboardCommandRouter.route(intent: .notificationScrollForward, store: transcriptOnly).outcome == .fallthroughToDefault)
    }

    @Test("T343 VG-04 root bridge dispatch follows router-owned scroll owner")
    func rootBridgeDispatchFollowsRouterOwnedScrollOwner() {
        let notificationStore = KeyboardOwnershipSceneFactory.chatScene(
            visibleNotificationSourceChatIds: ["n0"],
            mentionPickerVisible: false,
            composerFocused: true,
            notificationReplyFocusedSourceChatId: nil,
            actionMenuSourceChatId: nil
        )
        let transcriptStore = KeyboardOwnershipSceneFactory.chatScene(
            visibleNotificationSourceChatIds: [],
            mentionPickerVisible: false,
            composerFocused: false,
            notificationReplyFocusedSourceChatId: nil,
            actionMenuSourceChatId: nil
        )
        let composerStore = KeyboardOwnershipSceneFactory.chatScene(
            visibleNotificationSourceChatIds: [],
            mentionPickerVisible: false,
            composerFocused: true,
            notificationReplyFocusedSourceChatId: nil,
            actionMenuSourceChatId: nil
        )

        #expect(
            ChatRootKeyboardCommandDispatch.notificationName(
                for: .transcriptBubbleScrollForward,
                keyboardOwnershipStore: notificationStore
            ) == .clawlineScrollNotificationDownCommand
        )
        #expect(
            ChatRootKeyboardCommandDispatch.notificationName(
                for: .transcriptChatScrollBackward,
                keyboardOwnershipStore: notificationStore
            ) == .clawlineScrollNotificationUpCommand
        )
        #expect(
            ChatRootKeyboardCommandDispatch.notificationName(
                for: .transcriptBubbleScrollForward,
                keyboardOwnershipStore: transcriptStore
            ) == .clawlineScrollDownCommand
        )
        #expect(
            ChatRootKeyboardCommandDispatch.notificationName(
                for: .transcriptBubbleScrollForward,
                keyboardOwnershipStore: composerStore
            ) == nil
        )
    }

    @Test("T343 VG-07 adapters derive shortcut exposure from the central router vocabulary")
    func adaptersDeriveShortcutExposureFromCentralRouterVocabulary() {
        #expect(
            ChatAppCommandShortcut.keyCommandSpecs(notificationVisibleCount: 2).map(\.action) ==
                KeyboardCommandBridge.appSpecs(notificationVisibleCount: 2).compactMap { spec in
                    switch spec.intent {
                    case .focusPromptInput:
                        return .focusPromptInput
                    case .openStreamPopup:
                        return .openStreamPopup
                    case .navigatePreviousStream:
                        return .navigatePreviousStream
                    case .navigateNextStream:
                        return .navigateNextStream
                    case .transcriptBubbleScrollForward:
                        return .scrollDown
                    case .transcriptBubbleScrollBackward:
                        return .scrollUp
                    case .transcriptChatScrollForward:
                        return .scrollChatDown
                    case .transcriptChatScrollBackward:
                        return .scrollChatUp
                    case .notificationAssignedOpen, .notificationAssignedReply, .notificationAssignedDismiss:
                        return .notificationNumber
                    default:
                        return nil
                    }
                }
        )
        #expect(
            ChatAppCommandShortcut.prioritizedTextInputKeyCommandSpecs(notificationVisibleCount: 0).map(\.action) == [
                .scrollChatDown,
                .scrollChatUp
            ]
        )
        #expect(
            ChatAppCommandShortcut.prioritizedTextInputKeyCommandSpecs(notificationVisibleCount: 2).map(\.action) == [
                .scrollNotificationDown,
                .scrollNotificationUp,
                .scrollNotificationDown,
                .scrollNotificationUp,
                .notificationNumber,
                .notificationNumber,
                .notificationNumber,
                .notificationNumber,
                .notificationNumber,
                .notificationNumber
            ]
        )
        #expect(CrossChatNotificationGlobalShortcut.scrollSpecs(visibleNotificationCount: 2).map(\.input) == ["j", "k", "j", "k"])
    }

    @Test("T343 VG-07 registered command families gate surface ownership")
    func registeredCommandFamiliesGateSurfaceOwnership() {
        var store = KeyboardOwnershipStore()
        store.register(
            KeyboardSurfaceRecord(
                surfaceId: .notificationBubble("n0"),
                surfaceKind: .notificationBubble,
                parentSurfaceId: nil,
                lifecycleToken: "notification-bubble:n0",
                visible: true,
                active: true,
                focusedHint: false,
                commandFamilies: [.notificationScroll],
                domainRef: "n0"
            )
        )
        store.setNotificationShortcutMap([0: .notificationBubble("n0")])

        assertRoute(.notificationScrollForward, in: store, isHandledBy: .notificationBubble("n0"), rule: "PR-04")
        #expect(KeyboardCommandRouter.route(intent: .notificationAssignedOpen(0), store: store).outcome == .fallthroughToDefault)
    }

    @Test("T343 VG-07 focused notification scroll owner is resolved by router store")
    func focusedNotificationScrollOwnerIsResolvedByRouterStore() {
        let store = KeyboardOwnershipSceneFactory.chatScene(
            visibleNotificationSourceChatIds: ["n0", "n1"],
            mentionPickerVisible: false,
            composerFocused: true,
            notificationFocusedSourceChatId: "n1",
            notificationReplyFocusedSourceChatId: nil,
            actionMenuSourceChatId: nil
        )

        assertRoute(.notificationScrollForward, in: store, isHandledBy: .notificationBubble("n1"), rule: "PR-04")
    }

    @Test("T343 VG-07 app fallback requires a registered transcript surface")
    func appFallbackRequiresRegisteredTranscriptSurface() {
        let emptyStore = KeyboardOwnershipStore()
        let chatStore = KeyboardOwnershipSceneFactory.chatScene(
            visibleNotificationSourceChatIds: [],
            mentionPickerVisible: false,
            composerFocused: false,
            notificationReplyFocusedSourceChatId: nil,
            actionMenuSourceChatId: nil
        )

        #expect(KeyboardCommandRouter.route(intent: .focusPromptInput, store: emptyStore).outcome == .fallthroughToDefault)
        assertRoute(.focusPromptInput, in: chatStore, isHandledBy: .transcript, rule: "PR-07")
    }
}

@MainActor
private func assertRoute(
    _ intent: KeyboardCommandIntent,
    in store: KeyboardOwnershipStore,
    isHandledBy surfaceId: KeyboardSurfaceId,
    rule: String,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    let decision = KeyboardCommandRouter.route(intent: intent, store: store)
    #expect(decision.outcome == .handled(surfaceId), sourceLocation: sourceLocation)
    #expect(decision.priorityRule == rule, sourceLocation: sourceLocation)
    #expect(decision.participatingSurfaces.contains(surfaceId), sourceLocation: sourceLocation)
}
