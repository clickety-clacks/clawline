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

    private var notificationCommandsActive: Bool {
        crossChatNotificationCommand?.hasVisibleNotifications == true
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

            if notificationCommandsActive {
                ForEach(0...9, id: \.self) { index in
                    Button("Notification \(index) Actions") {
                        routeNotificationShortcut(.notificationAssignedOpen(index)) {
                            crossChatNotificationCommand?.openActionMenu(index)
                        }
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(index)")), modifiers: .command)
                    .disabled((crossChatNotificationCommand?.visibleCount ?? 0) <= index)

                    Button("Reply to Notification \(index)") {
                        routeNotificationShortcut(.notificationAssignedReply(index)) {
                            crossChatNotificationCommand?.reply(index)
                        }
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(index)")), modifiers: [.command, .option])
                    .disabled((crossChatNotificationCommand?.visibleCount ?? 0) <= index)

                    Button("Dismiss Notification \(index)") {
                        routeNotificationShortcut(.notificationAssignedDismiss(index)) {
                            crossChatNotificationCommand?.dismiss(index)
                        }
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(index)")), modifiers: [.command, .shift, .option])
                    .disabled((crossChatNotificationCommand?.visibleCount ?? 0) <= index)
                }
            } else {
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
        guard case .handled(.notificationBubble(_)) = KeyboardCommandRouter
            .route(intent: intent, store: routerStore())
            .outcome else { return }
        action()
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
}
