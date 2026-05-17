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
            .disabled(notificationCommandsActive)

            if notificationCommandsActive {
                ForEach(0...9, id: \.self) { index in
                    Button("Notification \(index) Actions") {
                        crossChatNotificationCommand?.openActionMenu(index)
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(index)")), modifiers: .command)
                    .disabled((crossChatNotificationCommand?.visibleCount ?? 0) <= index)

                    Button("Reply to Notification \(index)") {
                        crossChatNotificationCommand?.reply(index)
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(index)")), modifiers: [.command, .shift])
                    .disabled((crossChatNotificationCommand?.visibleCount ?? 0) <= index)

                    Button("Dismiss Notification \(index)") {
                        crossChatNotificationCommand?.dismiss(index)
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
                NotificationCenter.default.post(name: .clawlineFocusPromptInputCommand, object: nil)
            }
            .keyboardShortcut("l", modifiers: .command)

            Button("Open Streams") {
                NotificationCenter.default.post(name: .clawlineOpenStreamPopupCommand, object: nil)
            }
            .keyboardShortcut(";", modifiers: .command)

            Button("Previous Chat") {
                NotificationCenter.default.post(name: .clawlineNavigateToPreviousStreamCommand, object: nil)
            }
            .keyboardShortcut("h", modifiers: [.command, .shift])

            Button("Next Chat") {
                NotificationCenter.default.post(name: .clawlineNavigateToNextStreamCommand, object: nil)
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])

            Button("Cancel Current Prompt") {
                cancelCurrentPromptCommand?.presentConfirmation()
            }
            .keyboardShortcut(".", modifiers: .command)
            .disabled(cancelCurrentPromptCommand == nil)

            Divider()

            Button("Scroll Bubble Contents Down") {
                NotificationCenter.default.post(name: .clawlineScrollDownCommand, object: nil)
            }
            .keyboardShortcut("j", modifiers: .command)

            Button("Scroll Bubble Contents Up") {
                NotificationCenter.default.post(name: .clawlineScrollUpCommand, object: nil)
            }
            .keyboardShortcut("k", modifiers: .command)

            Button("Scroll Chat Down") {
                NotificationCenter.default.post(name: .clawlineScrollChatDownCommand, object: nil)
            }
            .keyboardShortcut("j", modifiers: [.command, .shift])

            Button("Scroll Chat Up") {
                NotificationCenter.default.post(name: .clawlineScrollChatUpCommand, object: nil)
            }
            .keyboardShortcut("k", modifiers: [.command, .shift])
        }
    }
}
