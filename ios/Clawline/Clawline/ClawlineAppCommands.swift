//
//  ClawlineAppCommands.swift
//  Clawline
//
//  Created by Codex on 3/29/26.
//

import SwiftUI

struct ClawlineAppCommands: Commands {
    let settingsManager: SettingsManager

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

            Button("Reset Font Size") {
                settingsManager.resetFontScale()
            }
            .keyboardShortcut("0", modifiers: .command)

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
        }
    }
}
