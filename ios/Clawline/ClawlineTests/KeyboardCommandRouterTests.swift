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
        #expect(KeyboardCommandBridge.intent(input: "3", modifierFlags: [.command, .alternate]) == .notificationAssignedReply(3))
        #expect(KeyboardCommandBridge.intent(input: "#", modifierFlags: [.command, .shift]) == nil)
        #expect(KeyboardCommandBridge.intent(input: "3", modifierFlags: [.command, .shift]) == nil)
        #expect(KeyboardCommandBridge.intent(input: "#", modifierFlags: [.command, .shift, .alternate]) == .notificationAssignedDismiss(3))
        #expect(KeyboardCommandBridge.intent(input: "-", modifierFlags: [.command]) == nil)
        #expect(KeyboardCommandBridge.intent(input: "-", modifierFlags: [.command, .shift, .alternate]) == .notificationDismissAll)
        #expect(KeyboardCommandBridge.intent(input: "_", modifierFlags: [.command, .shift, .alternate]) == .notificationDismissAll)
        #expect(KeyboardCommandBridge.intent(input: "\\", modifierFlags: [.command]) == .notificationToggleDock)
        #expect(KeyboardCommandBridge.intent(input: "`", modifierFlags: [.command]) == .toggleShowOnlyUserMessages)
        #expect(KeyboardCommandBridge.intent(input: "/", modifierFlags: [.command]) == nil)
        #expect(KeyboardCommandBridge.intent(input: ";", modifierFlags: [.command]) == .openStreamPopup)
        #expect(KeyboardCommandBridge.intent(input: ";", modifierFlags: [.control]) == .openStreamPopup)
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

    @Test("T1210 selector plain number shortcuts override notification open only while selector owns slot")
    func selectorPlainNumberShortcutsOverrideNotificationOpenOnlyWhileSelectorOwnsSlot() {
        var selectorStore = KeyboardOwnershipSceneFactory.chatScene(
            visibleNotificationSourceChatIds: ["n0", "n1"],
            mentionPickerVisible: false,
            composerFocused: true,
            notificationReplyFocusedSourceChatId: nil,
            actionMenuSourceChatId: nil
        )
        let selectorKeys = ["s_first", "s_second"]
        for record in StreamSelectorShortcutMap.records(selectableSessionKeys: selectorKeys) {
            selectorStore.register(record)
        }
        selectorStore.setChatSelectorShortcutMap(
            StreamSelectorShortcutMap.shortcutMap(selectableSessionKeys: selectorKeys)
        )

        assertRoute(.notificationAssignedOpen(1), in: selectorStore, isHandledBy: .chatSelectorRow("s_first"), rule: "PR-00")
        assertRoute(.notificationAssignedReply(1), in: selectorStore, isHandledBy: .notificationBubble("n1"), rule: "PR-03")
        assertRoute(.notificationAssignedDismiss(1), in: selectorStore, isHandledBy: .notificationBubble("n1"), rule: "PR-03")

        let closedStore = KeyboardOwnershipSceneFactory.chatScene(
            visibleNotificationSourceChatIds: ["n0", "n1"],
            mentionPickerVisible: false,
            composerFocused: true,
            notificationReplyFocusedSourceChatId: nil,
            actionMenuSourceChatId: nil
        )
        assertRoute(.notificationAssignedOpen(1), in: closedStore, isHandledBy: .notificationBubble("n1"), rule: "PR-03")
    }

    @Test("T1210 chat scene factory installs selector shortcut ownership into root store")
    func chatSceneFactoryInstallsSelectorShortcutOwnershipIntoRootStore() {
        let store = KeyboardOwnershipSceneFactory.chatScene(
            visibleNotificationSourceChatIds: ["n0", "n1"],
            visibleChatSelectorSessionKeys: ["s_first", "s_second"],
            mentionPickerVisible: false,
            composerFocused: true,
            notificationReplyFocusedSourceChatId: nil,
            actionMenuSourceChatId: nil
        )

        assertRoute(.notificationAssignedOpen(1), in: store, isHandledBy: .chatSelectorRow("s_first"), rule: "PR-00")
        assertRoute(.notificationAssignedReply(1), in: store, isHandledBy: .notificationBubble("n1"), rule: "PR-03")
    }

    @Test("T1210 selector map follows filtered visible ordering and maps tenth row to slot zero")
    func selectorMapFollowsFilteredVisibleOrderingAndMapsTenthRowToZero() {
        let filteredKeys = (0..<12).map { "filtered_\($0)" }
        let map = StreamSelectorShortcutMap.shortcutMap(selectableSessionKeys: filteredKeys)
        let store = StreamSelectorShortcutMap.store(selectableSessionKeys: filteredKeys)

        #expect(map[1] == .chatSelectorRow("filtered_0"))
        #expect(map[9] == .chatSelectorRow("filtered_8"))
        #expect(map[0] == .chatSelectorRow("filtered_9"))
        #expect(map.values.contains(.chatSelectorRow("filtered_10")) == false)
        assertRoute(.notificationAssignedOpen(0), in: store, isHandledBy: .chatSelectorRow("filtered_9"), rule: "PR-00")
        #expect(KeyboardCommandRouter.route(intent: .notificationAssignedOpen(4), store: StreamSelectorShortcutMap.store(selectableSessionKeys: [])).outcome == .fallthroughToDefault)
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

    @Test("T1154 Cmd-J/K notification scroll survives reply and popup lifecycle transitions")
    func notificationScrollSurvivesReplyAndPopupLifecycleTransitions() {
        let states = [
            KeyboardOwnershipSceneFactory.chatScene(
                visibleNotificationSourceChatIds: ["n0"],
                mentionPickerVisible: false,
                composerFocused: true,
                notificationReplyFocusedSourceChatId: nil,
                actionMenuSourceChatId: nil
            ),
            KeyboardOwnershipSceneFactory.chatScene(
                visibleNotificationSourceChatIds: ["n0"],
                mentionPickerVisible: false,
                composerFocused: false,
                notificationReplySourceChatIds: ["n0"],
                notificationReplyFocusedSourceChatId: "n0",
                actionMenuSourceChatId: nil
            ),
            KeyboardOwnershipSceneFactory.chatScene(
                visibleNotificationSourceChatIds: ["n0"],
                mentionPickerVisible: false,
                composerFocused: true,
                notificationReplySourceChatIds: [],
                notificationReplyFocusedSourceChatId: "n0",
                actionMenuSourceChatId: nil
            ),
            KeyboardOwnershipSceneFactory.chatScene(
                visibleNotificationSourceChatIds: ["n0"],
                mentionPickerVisible: true,
                mentionPickerHasCompletion: false,
                composerFocused: true,
                notificationReplyFocusedSourceChatId: nil,
                actionMenuSourceChatId: nil
            ),
            KeyboardOwnershipSceneFactory.chatScene(
                visibleNotificationSourceChatIds: ["n0"],
                mentionPickerVisible: true,
                mentionPickerHasCompletion: true,
                composerFocused: true,
                notificationReplyFocusedSourceChatId: nil,
                actionMenuSourceChatId: nil
            ),
            KeyboardOwnershipSceneFactory.chatScene(
                visibleNotificationSourceChatIds: ["n0"],
                mentionPickerVisible: false,
                composerFocused: false,
                notificationReplyFocusedSourceChatId: nil,
                actionMenuSourceChatId: nil
            ),
        ]

        for store in states {
            assertPhysicalShortcut(
                input: "j",
                modifiers: [.command],
                in: store,
                posts: [
                    .clawlineScrollNotificationDownCommand,
                    .clawlineScrollDownCommand
                ]
            )
            assertPhysicalShortcut(
                input: "k",
                modifiers: [.command],
                in: store,
                posts: [
                    .clawlineScrollNotificationUpCommand,
                    .clawlineScrollUpCommand
                ]
            )
        }
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
            KeyboardCommandRouter.route(
                intent: .transcriptBubbleScrollForward,
                store: notificationStore
            ).outcome == .handledMany([
                .transcript,
                .notificationBubble("n0")
            ])
        )
        #expect(
            ChatRootKeyboardCommandDispatch.notificationName(
                for: .transcriptBubbleScrollForward,
                keyboardOwnershipStore: notificationStore
            ) == .clawlineScrollNotificationDownCommand
        )
        #expect(
            ChatRootKeyboardCommandDispatch.notificationNames(
                for: .transcriptBubbleScrollForward,
                keyboardOwnershipStore: notificationStore
            ) == [
                .clawlineScrollNotificationDownCommand,
                .clawlineScrollDownCommand
            ]
        )
        #expect(
            ChatRootKeyboardCommandDispatch.notificationName(
                for: .transcriptChatScrollBackward,
                keyboardOwnershipStore: notificationStore
            ) == .clawlineScrollChatUpCommand
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
            ) == .clawlineScrollDownCommand
        )
    }

    @Test("Shortcut authority Cmd-J/K fan out through bubble scroll while Cmd-Shift-J/K stays transcript")
    func shortcutAuthorityPhysicalScrollShortcutsUseCorrectRootBridge() {
        for composerFocused in [false, true] {
            let store = KeyboardOwnershipSceneFactory.chatScene(
                visibleNotificationSourceChatIds: ["n0"],
                mentionPickerVisible: false,
                composerFocused: composerFocused,
                notificationReplyFocusedSourceChatId: nil,
                actionMenuSourceChatId: nil
            )

            assertPhysicalShortcut(
                input: "j",
                modifiers: [.command],
                in: store,
                posts: [
                    .clawlineScrollNotificationDownCommand,
                    .clawlineScrollDownCommand
                ]
            )
            assertPhysicalShortcut(
                input: "k",
                modifiers: [.command],
                in: store,
                posts: [
                    .clawlineScrollNotificationUpCommand,
                    .clawlineScrollUpCommand
                ]
            )
            assertPhysicalShortcut(
                input: "j",
                modifiers: [.command, .shift],
                in: store,
                posts: [.clawlineScrollChatDownCommand]
            )
            assertPhysicalShortcut(
                input: "k",
                modifiers: [.command, .shift],
                in: store,
                posts: [.clawlineScrollChatUpCommand]
            )
            assertPhysicalShortcut(
                input: "`",
                modifiers: [.command],
                in: store,
                posts: [.clawlineToggleShowOnlyUserMessagesCommand]
            )
        }
    }

    @Test("Shortcut authority app command source leaves Cmd-J/K and Cmd-Shift-J/K on root fan-out path")
    func appCommandSourceLeavesScrollShortcutsOnRootFanOutPath() {
        for composerFocused in [false, true] {
            let store = KeyboardOwnershipSceneFactory.chatScene(
                visibleNotificationSourceChatIds: ["n0"],
                mentionPickerVisible: false,
                composerFocused: composerFocused,
                notificationReplyFocusedSourceChatId: nil,
                actionMenuSourceChatId: nil
            )

            #expect(
                ChatAppShortcutCommandDispatch.action(
                    for: .transcriptBubbleScrollForward,
                    keyboardOwnershipStore: store
                ) == .postKeyboardIntent
            )
            #expect(
                ChatAppShortcutCommandDispatch.action(
                    for: .transcriptBubbleScrollBackward,
                    keyboardOwnershipStore: store
                ) == .postKeyboardIntent
            )
            #expect(
                ChatAppShortcutCommandDispatch.action(
                    for: .transcriptChatScrollForward,
                    keyboardOwnershipStore: store
                ) == .postKeyboardIntent
            )
            #expect(
                ChatAppShortcutCommandDispatch.action(
                    for: .transcriptChatScrollBackward,
                    keyboardOwnershipStore: store
                ) == .postKeyboardIntent
            )
        }
    }

    @Test("T347-10 app command source preserves no-notification transcript fallback")
    func appCommandSourcePreservesNoNotificationTranscriptFallback() {
        for composerFocused in [false, true] {
            let store = KeyboardOwnershipSceneFactory.chatScene(
                visibleNotificationSourceChatIds: [],
                mentionPickerVisible: false,
                composerFocused: composerFocused,
                notificationReplyFocusedSourceChatId: nil,
                actionMenuSourceChatId: nil
            )

            #expect(
                ChatAppShortcutCommandDispatch.action(
                    for: .transcriptBubbleScrollForward,
                    keyboardOwnershipStore: store
                ) == .postKeyboardIntent
            )
            #expect(
                ChatAppShortcutCommandDispatch.action(
                    for: .transcriptChatScrollForward,
                    keyboardOwnershipStore: store
                ) == .postKeyboardIntent
            )
        }
    }

    @Test("T347-10 no-notification physical shift J/K stays transcript owned across composer focus")
    func noNotificationPhysicalShiftScrollStaysTranscriptOwnedAcrossComposerFocus() {
        for composerFocused in [false, true] {
            let store = KeyboardOwnershipSceneFactory.chatScene(
                visibleNotificationSourceChatIds: [],
                mentionPickerVisible: false,
                composerFocused: composerFocused,
                notificationReplyFocusedSourceChatId: nil,
                actionMenuSourceChatId: nil
            )

            assertPhysicalShortcut(
                input: "j",
                modifiers: [.command, .shift],
                in: store,
                posts: [.clawlineScrollChatDownCommand]
            )
            assertPhysicalShortcut(
                input: "k",
                modifiers: [.command, .shift],
                in: store,
                posts: [.clawlineScrollChatUpCommand]
            )
        }
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
                    case .toggleShowOnlyUserMessages:
                        return .toggleShowOnlyUserMessages
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
                .openStreamPopup,
                .openStreamPopup,
                .toggleShowOnlyUserMessages,
                .scrollDown,
                .scrollUp,
                .scrollChatDown,
                .scrollChatUp
            ]
        )
        #expect(
            ChatAppCommandShortcut.prioritizedTextInputKeyCommandSpecs(notificationVisibleCount: 2).map(\.action) == [
                .openStreamPopup,
                .openStreamPopup,
                .toggleShowOnlyUserMessages,
                .scrollDown,
                .scrollUp,
                .scrollChatDown,
                .scrollChatUp,
                .notificationNumber,
                .notificationNumber,
                .notificationNumber,
                .notificationNumber,
                .notificationNumber,
                .notificationNumber
            ]
        )
        #expect(CrossChatNotificationGlobalShortcut.scrollSpecs(visibleNotificationCount: 2).map(\.input) == ["j", "k"])
        #expect(
            !ChatAppCommandShortcut.keyCommandSpecs(notificationVisibleCount: 2).contains { spec in
                spec.action == .scrollNotificationDown || spec.action == .scrollNotificationUp
            }
        )
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
    #expect(decision.outcome.containsHandledSurface(surfaceId), sourceLocation: sourceLocation)
    #expect(decision.priorityRule == rule, sourceLocation: sourceLocation)
    #expect(decision.participatingSurfaces.contains(surfaceId), sourceLocation: sourceLocation)
}

@MainActor
private func assertPhysicalShortcut(
    input: String,
    modifiers: UIKeyModifierFlags,
    in store: KeyboardOwnershipStore,
    posts expectedNames: [Notification.Name],
    sourceLocation: SourceLocation = #_sourceLocation
) {
    let intent = KeyboardCommandBridge.intent(input: input, modifierFlags: modifiers)
    #expect(intent != nil, sourceLocation: sourceLocation)
    #expect(
        intent.map {
            ChatRootKeyboardCommandDispatch.notificationNames(
                for: $0,
                keyboardOwnershipStore: store
            )
        } == expectedNames,
        sourceLocation: sourceLocation
    )
}
