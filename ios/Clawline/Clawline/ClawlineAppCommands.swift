//
//  ClawlineAppCommands.swift
//  Clawline
//
//  Created by Codex on 3/29/26.
//

import SwiftUI

struct ClawlineAppCommands: Commands {
    let settingsManager: SettingsManager
    @FocusedValue(\.cancelCurrentPromptCommand) private var cancelCurrentPromptCommand
    @FocusedValue(\.crossChatNotificationCommand) private var crossChatNotificationCommand

    private var plainNumberCommandsActive: Bool {
        guard let crossChatNotificationCommand else { return false }
        return crossChatNotificationCommand.hasVisibleNotifications
            || crossChatNotificationCommand.hasActiveChatSelectorShortcuts
    }

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings...") {
                settingsManager.toggleSettings()
            }
            .keyboardShortcut(",", modifiers: .command)
        }

        CommandMenu("View") {
            Button("Increase Font Size") {
                settingsManager.increaseFontScale()
            }
            .keyboardShortcut("=", modifiers: .command)

            Button("Decrease Font Size") {
                settingsManager.decreaseFontScale()
            }
            .keyboardShortcut("-", modifiers: .command)

            if plainNumberCommandsActive {
                ForEach(0...9, id: \.self) { index in
                    if let owner = ChatAppShortcutCommandDispatch.plainNumberOpenCommandOwner(
                        index: index,
                        keyboardOwnershipStore: routerStore()
                    ) {
                        Button(owner.menuTitle(forIndex: index)) {
                            routeNotificationShortcut(.notificationAssignedOpen(index)) {
                                crossChatNotificationCommand?.openActionMenu(index)
                            }
                        }
                        .keyboardShortcut(KeyEquivalent(Character("\(index)")), modifiers: .command)
                    }

                    if (crossChatNotificationCommand?.visibleCount ?? 0) > index {
                        Button("Reply to Notification \(index)") {
                            routeNotificationShortcut(.notificationAssignedReply(index)) {
                                crossChatNotificationCommand?.reply(index)
                            }
                        }
                        .keyboardShortcut(KeyEquivalent(Character("\(index)")), modifiers: [.command, .option])

                        Button("Dismiss Notification \(index)") {
                            routeNotificationShortcut(.notificationAssignedDismiss(index)) {
                                crossChatNotificationCommand?.dismiss(index)
                            }
                        }
                        .keyboardShortcut(KeyEquivalent(Character("\(index)")), modifiers: [.command, .shift, .option])
                    }
                }
            }

            if !ChatAppShortcutCommandDispatch.plainNumberOpenCommandIsOwned(
                index: 0,
                keyboardOwnershipStore: routerStore()
            ) {
                Button("Reset Font Size") {
                    settingsManager.resetFontScale()
                }
                .keyboardShortcut("0", modifiers: .command)
            }

            Divider()

            Button("Focus Prompt Input") {
                routeAppShortcut(.focusPromptInput)
            }
            .keyboardShortcut("l", modifiers: .command)

            Button("Open Streams") {
                routeAppShortcut(.openStreamPopup)
            }
            .keyboardShortcut(";", modifiers: .command)

            Button("Previous Chat") {
                routeAppShortcut(.navigatePreviousStream)
            }
            .keyboardShortcut("h", modifiers: [.command, .shift])

            Button("Next Chat") {
                routeAppShortcut(.navigateNextStream)
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])

            Button("Cancel Current Prompt") {
                cancelCurrentPromptCommand?.presentConfirmation()
            }
            .keyboardShortcut(".", modifiers: .command)
            .disabled(cancelCurrentPromptCommand == nil)

            Divider()

            Button("Scroll Bubble Contents Down") {
                routeAppShortcut(.transcriptBubbleScrollForward)
            }
            .keyboardShortcut("j", modifiers: .command)

            Button("Scroll Bubble Contents Up") {
                routeAppShortcut(.transcriptBubbleScrollBackward)
            }
            .keyboardShortcut("k", modifiers: .command)

            Button("Scroll Chat Down") {
                routeAppShortcut(.transcriptChatScrollForward)
            }
            .keyboardShortcut("j", modifiers: [.command, .shift])

            Button("Scroll Chat Up") {
                routeAppShortcut(.transcriptChatScrollBackward)
            }
            .keyboardShortcut("k", modifiers: [.command, .shift])
        }
    }

    private func routerStore() -> KeyboardOwnershipStore {
        crossChatNotificationCommand?.keyboardOwnershipStore ?? KeyboardOwnershipSceneFactory.chatScene(
            visibleNotificationSourceChatIds: [],
            mentionPickerVisible: false,
            composerFocused: false,
            notificationReplyFocusedSourceChatId: nil,
            actionMenuSourceChatId: nil
        )
    }

    private func routeNotificationShortcut(
        _ intent: KeyboardCommandIntent,
        perform action: () -> Void
    ) {
        switch KeyboardCommandRouter.route(intent: intent, store: routerStore()).outcome {
        case .handled(.notificationBubble(_)):
            action()
        case .handled(.chatSelectorRow(_)):
            if case .notificationAssignedOpen = intent {
                NotificationCenter.default.post(name: .clawlineKeyboardCommandIntent, object: intent)
            }
        default:
            return
        }
    }

    private func routeAppShortcut(_ intent: KeyboardCommandIntent) {
        switch ChatAppShortcutCommandDispatch.action(
            for: intent,
            keyboardOwnershipStore: routerStore()
        ) {
        case .postKeyboardIntent:
            NotificationCenter.default.post(name: .clawlineKeyboardCommandIntent, object: intent)
        case .scrollNotificationDown:
            crossChatNotificationCommand?.scrollDown()
        case .scrollNotificationUp:
            crossChatNotificationCommand?.scrollUp()
        }
    }
}

enum ChatAppShortcutCommandDispatch {
    enum Action: Equatable {
        case postKeyboardIntent
        case scrollNotificationDown
        case scrollNotificationUp
    }

    enum PlainNumberOpenOwner: Equatable {
        case notification
        case chatSelector

        func menuTitle(forIndex index: Int) -> String {
            switch self {
            case .notification:
                return "Notification \(index) Actions"
            case .chatSelector:
                return "Select Chat \(index)"
            }
        }
    }

    static func action(
        for intent: KeyboardCommandIntent,
        keyboardOwnershipStore: KeyboardOwnershipStore
    ) -> Action {
        let route = KeyboardCommandRouter.route(intent: intent, store: keyboardOwnershipStore)
        guard case .handled(.notificationBubble(_)) = route.outcome else {
            return .postKeyboardIntent
        }

        switch intent {
        case .notificationScrollForward:
            return .scrollNotificationDown
        case .notificationScrollBackward:
            return .scrollNotificationUp
        default:
            return .postKeyboardIntent
        }
    }

    static func plainNumberOpenCommandIsOwned(
        index: Int,
        keyboardOwnershipStore: KeyboardOwnershipStore
    ) -> Bool {
        plainNumberOpenCommandOwner(
            index: index,
            keyboardOwnershipStore: keyboardOwnershipStore
        ) != nil
    }

    static func plainNumberOpenCommandOwner(
        index: Int,
        keyboardOwnershipStore: KeyboardOwnershipStore
    ) -> PlainNumberOpenOwner? {
        switch KeyboardCommandRouter.route(
            intent: .notificationAssignedOpen(index),
            store: keyboardOwnershipStore
        ).outcome {
        case .handled(.notificationBubble(_)):
            return .notification
        case .handled(.chatSelectorRow(_)):
            return .chatSelector
        default:
            return nil
        }
    }
}
