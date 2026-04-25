//
//  PromptFocusShortcutActivationTests.swift
//  ClawlineTests
//
//  Created by Codex on 4/24/26.
//

import Testing
import UIKit
@testable import Clawline

struct PromptFocusShortcutActivationTests {
    @Test("No-text prompt focus shortcuts keep Cmd-L out of the unmodified host")
    func noTextPromptFocusShortcutsKeepCommandLOutOfTheUnmodifiedHost() {
        #expect(
            !PromptFocusShortcutConfiguration.keyCommandSpecs.contains { spec in
                spec.input == "l"
                    && spec.modifierFlags == [.command]
                    && spec.action == .focusPromptInput
            }
        )
    }

    @Test("App command shortcuts use Cmd-L focus, Cmd-semicolon, Cmd-Shift navigation, and scroll")
    func appCommandShortcutsUseCommandLFocusCommandSemicolonCommandShiftNavigationAndScroll() {
        #expect(
            ChatAppCommandShortcut.keyCommandSpecs.contains { spec in
                spec.input == "l"
                    && spec.modifierFlags == [.command]
                    && spec.action.selector == #selector(UIResponder.clawlineFocusPromptInputCommand(_:))
            }
        )
        #expect(
            ChatAppCommandShortcut.keyCommandSpecs.contains { spec in
                spec.input == ";"
                    && spec.modifierFlags == [.command]
                    && spec.action.selector == #selector(UIResponder.clawlineOpenStreamPopupCommand(_:))
            }
        )
        #expect(
            ChatAppCommandShortcut.keyCommandSpecs.contains { spec in
                spec.input == "h"
                    && spec.modifierFlags == [.command, .shift]
                    && spec.action.selector == #selector(UIResponder.clawlineNavigateToPreviousStreamCommand(_:))
            }
        )
        #expect(
            !ChatAppCommandShortcut.keyCommandSpecs.contains { spec in
                spec.input == "l"
                    && spec.modifierFlags == [.command]
                    && spec.action.selector == #selector(UIResponder.clawlineNavigateToNextStreamCommand(_:))
            }
        )
        #expect(
            ChatAppCommandShortcut.keyCommandSpecs.contains { spec in
                spec.input == "l"
                    && spec.modifierFlags == [.command, .shift]
                    && spec.action.selector == #selector(UIResponder.clawlineNavigateToNextStreamCommand(_:))
            }
        )
        #expect(
            ChatAppCommandShortcut.keyCommandSpecs.contains { spec in
                spec.input == "j"
                    && spec.modifierFlags == [.command, .shift]
                    && spec.action.selector == #selector(UIResponder.clawlineScrollDownCommand(_:))
            }
        )
        #expect(
            ChatAppCommandShortcut.keyCommandSpecs.contains { spec in
                spec.input == "k"
                    && spec.modifierFlags == [.command, .shift]
                    && spec.action.selector == #selector(UIResponder.clawlineScrollUpCommand(_:))
            }
        )
        #expect(
            !ChatAppCommandShortcut.keyCommandSpecs.contains { spec in
                ["h", "j", "k"].contains(spec.input) && spec.modifierFlags == [.command]
            }
        )
    }

    @Test("No-text shortcut host owns only unmodified prompt and popup keys")
    func noTextShortcutHostOwnsOnlyUnmodifiedPromptAndPopupKeys() {
        #expect(
            PromptFocusShortcutConfiguration.keyCommandSpecs.map(\.input) == ["/", " ", "\r"]
        )
        #expect(
            PromptFocusShortcutConfiguration.keyCommandSpecs.allSatisfy { $0.modifierFlags.isEmpty }
        )
    }

    @Test("Prompt text input owns Escape as the text release key")
    @MainActor
    func promptTextInputOwnsEscapeAsTheTextReleaseKey() {
        let textView = PastableTextView(frame: .zero, textContainer: nil)
        let firstEscapeCommand = textView.keyCommands?.first { command in
            command.input == UIKeyCommand.inputEscape && command.modifierFlags.isEmpty
        }

        #expect(firstEscapeCommand?.action == Selector(("didPressEscape:")))
    }

    @Test("Prompt text input reports responder focus transitions")
    @MainActor
    func promptTextInputReportsResponderFocusTransitions() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 120))
        let textView = PastableTextView(frame: CGRect(x: 0, y: 0, width: 320, height: 44), textContainer: nil)
        var reportedFocusStates: [Bool] = []
        textView.onResponderFocusChange = { isFocused in
            reportedFocusStates.append(isFocused)
        }
        window.addSubview(textView)
        window.makeKeyAndVisible()

        let didFocus = textView.becomeFirstResponder()
        let didRelease = textView.resignFirstResponder()
        window.isHidden = true

        #expect(didFocus)
        #expect(didRelease)
        #expect(reportedFocusStates == [true, false])
    }

    @Test("Shortcut routing separates app commands from no-text responder keys")
    func shortcutRoutingSeparatesAppCommandsFromNoTextResponderKeys() {
        #expect(ChatShortcutRouting.owner(input: "l", modifierFlags: [.command, .shift]) == .appCommand)
        #expect(ChatShortcutRouting.owner(input: "h", modifierFlags: [.command, .shift]) == .appCommand)
        #expect(ChatShortcutRouting.owner(input: "j", modifierFlags: [.command, .shift]) == .appCommand)
        #expect(ChatShortcutRouting.owner(input: "k", modifierFlags: [.command, .shift]) == .appCommand)
        #expect(ChatShortcutRouting.owner(input: ";", modifierFlags: [.command]) == .appCommand)
        #expect(ChatShortcutRouting.owner(input: "l", modifierFlags: [.command]) == .appCommand)
        #expect(ChatShortcutRouting.owner(input: "h", modifierFlags: [.command]) == .textInput)
        #expect(ChatShortcutRouting.owner(input: "j", modifierFlags: [.command]) == .textInput)
        #expect(ChatShortcutRouting.owner(input: "k", modifierFlags: [.command]) == .textInput)
        #expect(ChatShortcutRouting.owner(input: "/", modifierFlags: [.command]) == .textInput)
        #expect(ChatShortcutRouting.owner(input: "/", modifierFlags: []) == .noTextResponder)
        #expect(ChatShortcutRouting.owner(input: " ", modifierFlags: []) == .noTextResponder)
        #expect(ChatShortcutRouting.owner(input: "\r", modifierFlags: []) == .noTextResponder)
    }

    @Test("Keyboard page scroll shortcuts only enable when chat surface owns scroll")
    func keyboardPageScrollShortcutsOnlyEnableWhenChatSurfaceOwnsScroll() {
        #expect(
            ChatKeyboardScrollRouting.isEnabled(
                platformSupportsKeyboardNavigation: true,
                streamPopupRoute: .closed,
                activeSheetPresented: false,
                photosPickerPresented: false,
                fileImporterPresented: false
            )
        )
        #expect(
            !ChatKeyboardScrollRouting.isEnabled(
                platformSupportsKeyboardNavigation: false,
                streamPopupRoute: .closed,
                activeSheetPresented: false,
                photosPickerPresented: false,
                fileImporterPresented: false
            )
        )
        #expect(
            !ChatKeyboardScrollRouting.isEnabled(
                platformSupportsKeyboardNavigation: true,
                streamPopupRoute: .popup(searchFocus: .none),
                activeSheetPresented: false,
                photosPickerPresented: false,
                fileImporterPresented: false
            )
        )
        #expect(
            !ChatKeyboardScrollRouting.isEnabled(
                platformSupportsKeyboardNavigation: true,
                streamPopupRoute: .closed,
                activeSheetPresented: true,
                photosPickerPresented: false,
                fileImporterPresented: false
            )
        )
        #expect(
            !ChatKeyboardScrollRouting.isEnabled(
                platformSupportsKeyboardNavigation: true,
                streamPopupRoute: .closed,
                activeSheetPresented: false,
                photosPickerPresented: true,
                fileImporterPresented: false
            )
        )
        #expect(
            !ChatKeyboardScrollRouting.isEnabled(
                platformSupportsKeyboardNavigation: true,
                streamPopupRoute: .closed,
                activeSheetPresented: false,
                photosPickerPresented: false,
                fileImporterPresented: true
            )
        )
    }

    @Test("Chat keyboard navigation follows stream order without wrapping")
    func chatKeyboardNavigationFollowsStreamOrderWithoutWrapping() {
        let sessionKeys = ["left", "middle", "right"]

        #expect(
            ChatKeyboardNavigation.targetSessionKey(
                sessionKeys: sessionKeys,
                currentSessionKey: "middle",
                step: -1
            ) == "left"
        )
        #expect(
            ChatKeyboardNavigation.targetSessionKey(
                sessionKeys: sessionKeys,
                currentSessionKey: "middle",
                step: 1
            ) == "right"
        )
        #expect(
            ChatKeyboardNavigation.targetSessionKey(
                sessionKeys: sessionKeys,
                currentSessionKey: "left",
                step: -1
            ) == nil
        )
        #expect(
            ChatKeyboardNavigation.targetSessionKey(
                sessionKeys: sessionKeys,
                currentSessionKey: "right",
                step: 1
            ) == nil
        )
    }

    @Test("Prompt focus shortcut does not steal focus from active text input")
    func promptFocusShortcutDoesNotStealFocusFromActiveTextInput() {
        #expect(
            PromptFocusShortcutActivation.action(
                isShortcutEnabled: true,
                isAlreadyFirstResponder: false,
                currentFirstResponderIsTextInput: false,
                currentFirstResponderOwnsEmbeddedScroll: false,
                canRetryAfterTextInput: true
            ) == .activate
        )
        #expect(
            PromptFocusShortcutActivation.action(
                isShortcutEnabled: true,
                isAlreadyFirstResponder: false,
                currentFirstResponderIsTextInput: true,
                currentFirstResponderOwnsEmbeddedScroll: false,
                canRetryAfterTextInput: false
            ) == .skip
        )
        #expect(
            PromptFocusShortcutActivation.action(
                isShortcutEnabled: false,
                isAlreadyFirstResponder: false,
                currentFirstResponderIsTextInput: false,
                currentFirstResponderOwnsEmbeddedScroll: false,
                canRetryAfterTextInput: true
            ) == .skip
        )
        #expect(
            PromptFocusShortcutActivation.action(
                isShortcutEnabled: true,
                isAlreadyFirstResponder: true,
                currentFirstResponderIsTextInput: false,
                currentFirstResponderOwnsEmbeddedScroll: false,
                canRetryAfterTextInput: true
            ) == .skip
        )
    }

    @Test("Prompt focus shortcut does not steal focus from embedded scroll input")
    func promptFocusShortcutDoesNotStealFocusFromEmbeddedScrollInput() {
        #expect(
            PromptFocusShortcutActivation.action(
                isShortcutEnabled: true,
                isAlreadyFirstResponder: false,
                currentFirstResponderIsTextInput: false,
                currentFirstResponderOwnsEmbeddedScroll: true,
                canRetryAfterTextInput: true
            ) == .skip
        )
    }

    @Test("Prompt focus shortcut retries after Esc text input handoff")
    func promptFocusShortcutRetriesAfterEscTextInputHandoff() {
        #expect(
            PromptFocusShortcutActivation.action(
                isShortcutEnabled: true,
                isAlreadyFirstResponder: false,
                currentFirstResponderIsTextInput: true,
                currentFirstResponderOwnsEmbeddedScroll: false,
                canRetryAfterTextInput: true
            ) == .retryAfterTextInputResigns
        )
    }
}
