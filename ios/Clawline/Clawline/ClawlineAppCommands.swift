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

            Button("Open Streams") {
                NotificationCenter.default.post(name: .clawlineOpenStreamPopupCommand, object: nil)
            }
            .keyboardShortcut("/", modifiers: .command)

            Divider()

            Button("Scroll to Bottom") {
                NotificationCenter.default.post(name: .clawlineScrollToBottomCommand, object: nil)
            }
            .keyboardShortcut("j", modifiers: .command)

            Button("Scroll to Top") {
                NotificationCenter.default.post(name: .clawlineScrollToTopCommand, object: nil)
            }
            .keyboardShortcut("k", modifiers: .command)
        }
    }
}
