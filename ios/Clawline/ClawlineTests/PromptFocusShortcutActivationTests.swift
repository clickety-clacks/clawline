//
//  PromptFocusShortcutActivationTests.swift
//  ClawlineTests
//
//  Created by Codex on 4/24/26.
//

import Testing
import SwiftUI
import UIKit
@testable import Clawline

struct PromptFocusShortcutActivationTests {
    @Test("T307 notification reply input presents Send return key and five-line cap")
    @MainActor
    func notificationReplyInputUsesSendReturnKeyAndFiveLineCap() {
        let textView = NotificationReplyUITextView()
        let font = UIFont.systemFont(ofSize: 15)

        NotificationReplyTextInputConfiguration.configure(
            textView,
            font: font,
            textColor: .label,
            tintColor: .systemGreen,
            visibleNotificationCount: 3
        )

        #expect(textView.returnKeyType == .send)
        #expect(textView.font == font)
        #expect(textView.visibleNotificationCount == 3)
        #expect(textView.textContainer.widthTracksTextView)
        #expect(textView.contentHuggingPriority(for: .horizontal) == .defaultLow)
        #expect(textView.contentCompressionResistancePriority(for: .horizontal) == .defaultLow)
        #expect(
            NotificationReplyTextInputConfiguration.height(
                forVisibleLines: NotificationReplyTextInputConfiguration.maximumVisibleLines,
                font: font
            ) == ceil(font.lineHeight * 5)
        )
    }

    @Test("T307 notification reply input wraps long drafts inside proposed width")
    @MainActor
    func notificationReplyInputWrapsLongDraftsInsideProposedWidth() {
        let textView = NotificationReplyUITextView()
        let font = UIFont.systemFont(ofSize: 15)
        NotificationReplyTextInputConfiguration.configure(
            textView,
            font: font,
            textColor: .label,
            tintColor: .systemGreen,
            visibleNotificationCount: 1
        )
        textView.text = String(repeating: "long draft text ", count: 20)

        let proposedWidth: CGFloat = 120
        let fitting = textView.sizeThatFits(
            CGSize(width: proposedWidth, height: .greatestFiniteMagnitude)
        )

        #expect(fitting.width <= proposedWidth + 0.5)
        #expect(
            fitting.height > NotificationReplyTextInputConfiguration.height(
                forVisibleLines: 1,
                font: font
            )
        )
    }

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

    @Test("App command shortcuts use Cmd-L focus, Cmd-semicolon, Cmd-Shift navigation, Cmd-J/K bubble scroll, and Cmd-Shift-J/K chat scroll")
    func appCommandShortcutsUseCommandLFocusCommandSemicolonCommandShiftNavigationCommandJKBubbleScrollAndCommandShiftJKChatScroll() {
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
                    && spec.modifierFlags == [.command]
                    && spec.action.selector == #selector(UIResponder.clawlineScrollDownCommand(_:))
            }
        )
        #expect(
            ChatAppCommandShortcut.keyCommandSpecs.contains { spec in
                spec.input == "k"
                    && spec.modifierFlags == [.command]
                    && spec.action.selector == #selector(UIResponder.clawlineScrollUpCommand(_:))
            }
        )
        #expect(
            ChatAppCommandShortcut.keyCommandSpecs.contains { spec in
                spec.input == "j"
                    && spec.modifierFlags == [.command, .shift]
                    && spec.action.selector == #selector(UIResponder.clawlineScrollChatDownCommand(_:))
            }
        )
        #expect(
            ChatAppCommandShortcut.keyCommandSpecs.contains { spec in
                spec.input == "k"
                    && spec.modifierFlags == [.command, .shift]
                    && spec.action.selector == #selector(UIResponder.clawlineScrollChatUpCommand(_:))
            }
        )
        #expect(!ChatAppCommandShortcut.keyCommandSpecs.contains { spec in
            spec.input == "0" && spec.modifierFlags == [.command]
        })
        let notificationCommandSpecs = ChatAppCommandShortcut.keyCommandSpecs(
            notificationVisibleCount: 10
        )
        for index in 0...9 {
            #expect(notificationCommandSpecs.contains { spec in
                spec.input == "\(index)"
                    && spec.modifierFlags == [.command]
                    && spec.action.selector == #selector(UIResponder.clawlineNotificationNumberCommand(_:))
            })
            #expect(notificationCommandSpecs.contains { spec in
                spec.input == "\(index)"
                    && spec.modifierFlags == [.command, .shift]
                    && spec.action.selector == #selector(UIResponder.clawlineNotificationNumberCommand(_:))
            })
            #expect(notificationCommandSpecs.contains { spec in
                spec.input == "\(index)"
                    && spec.modifierFlags == [.command, .shift, .alternate]
                    && spec.action.selector == #selector(UIResponder.clawlineNotificationNumberCommand(_:))
            })
        }
        #expect(
            !ChatAppCommandShortcut.keyCommandSpecs.contains { spec in
                spec.input == "h" && spec.modifierFlags == [.command]
            }
        )
        #expect(
            ChatAppCommandShortcut.notificationScrollKeyCommandSpecs.map(\.action) == [
                .scrollDown,
                .scrollUp,
                .scrollChatDown,
                .scrollChatUp
            ]
        )
    }

    @Test("No-text shortcut host owns only unmodified prompt and popup keys")
    func noTextShortcutHostOwnsOnlyUnmodifiedPromptAndPopupKeys() {
        #expect(
            PromptFocusShortcutConfiguration.keyCommandSpecs.map(\.input) == ["/", ";", " ", "\r"]
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

    @Test("Prompt text input exposes app scroll commands before base text-view commands")
    @MainActor
    func promptTextInputExposesAppScrollCommandsBeforeBaseTextViewCommands() {
        let textView = PastableTextView(frame: .zero, textContainer: nil)
        textView.notificationVisibleCount = 2

        let firstCommandJ = textView.keyCommands?.first { command in
            command.input == "j" && command.modifierFlags == [.command]
        }
        let firstCommandShiftK = textView.keyCommands?.first { command in
            command.input == "k" && command.modifierFlags == [.command, .shift]
        }

        #expect(firstCommandJ?.action == #selector(UIResponder.clawlineScrollDownCommand(_:)))
        #expect(firstCommandShiftK?.action == #selector(UIResponder.clawlineScrollChatUpCommand(_:)))
    }

    @Test("Text input priority is limited to visible notification-owned shortcuts")
    @MainActor
    func textInputPriorityIsLimitedToVisibleNotificationOwnedShortcuts() {
        #expect(
            ChatAppCommandShortcut.prioritizesTextInputBaseCommand(
                input: "j",
                modifierFlags: [.command],
                notificationVisibleCount: 0
            ) == false
        )
        #expect(
            ChatAppCommandShortcut.prioritizesTextInputBaseCommand(
                input: "j",
                modifierFlags: [.command],
                notificationVisibleCount: 2
            )
        )
        #expect(
            ChatAppCommandShortcut.prioritizesTextInputBaseCommand(
                input: "k",
                modifierFlags: [.command, .shift],
                notificationVisibleCount: 2
            )
        )
        #expect(
            ChatAppCommandShortcut.prioritizesTextInputBaseCommand(
                input: "1",
                modifierFlags: [.command, .shift, .alternate],
                notificationVisibleCount: 2
            )
        )
        #expect(
            ChatAppCommandShortcut.prioritizesTextInputBaseCommand(
                input: "l",
                modifierFlags: [.command],
                notificationVisibleCount: 2
            ) == false
        )
        #expect(
            ChatAppCommandShortcut.prioritizesTextInputBaseCommand(
                input: "1",
                modifierFlags: [.command, .control],
                notificationVisibleCount: 2
            ) == false
        )
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
        #expect(ChatShortcutRouting.owner(input: ";", modifierFlags: [.command]) == .appCommand)
        #expect(ChatShortcutRouting.owner(input: "l", modifierFlags: [.command]) == .appCommand)
        #expect(ChatShortcutRouting.owner(input: "j", modifierFlags: [.command]) == .appCommand)
        #expect(ChatShortcutRouting.owner(input: "k", modifierFlags: [.command]) == .appCommand)
        #expect(ChatShortcutRouting.owner(input: "j", modifierFlags: [.command, .shift]) == .appCommand)
        #expect(ChatShortcutRouting.owner(input: "k", modifierFlags: [.command, .shift]) == .appCommand)
        #expect(ChatShortcutRouting.owner(input: "h", modifierFlags: [.command]) == .textInput)
        #expect(ChatShortcutRouting.owner(input: "/", modifierFlags: [.command]) == .textInput)
        #expect(ChatShortcutRouting.owner(input: "/", modifierFlags: []) == .noTextResponder)
        #expect(ChatShortcutRouting.owner(input: ";", modifierFlags: []) == .noTextResponder)
        #expect(ChatShortcutRouting.owner(input: " ", modifierFlags: []) == .noTextResponder)
        #expect(ChatShortcutRouting.owner(input: "\r", modifierFlags: []) == .noTextResponder)
    }

    @Test("Visible bubble content scroller targets all visible top-level vertical scroll views")
    @MainActor
    func visibleBubbleContentScrollerTargetsAllVisibleTopLevelVerticalScrollViews() {
        let viewport = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
        let root = UIView(frame: viewport.bounds)
        viewport.addSubview(root)

        let first = makeVerticalScrollView(frame: CGRect(x: 0, y: 10, width: 200, height: 100), contentHeight: 420)
        let nested = makeVerticalScrollView(frame: CGRect(x: 0, y: 0, width: 180, height: 80), contentHeight: 300)
        first.addSubview(nested)
        let second = makeVerticalScrollView(frame: CGRect(x: 0, y: 150, width: 200, height: 120), contentHeight: 420)
        let offscreen = makeVerticalScrollView(frame: CGRect(x: 0, y: 450, width: 200, height: 120), contentHeight: 420)
        root.addSubview(first)
        root.addSubview(second)
        root.addSubview(offscreen)

        let visible = ChatVisibleBubbleContentScroll.topLevelVisibleVerticalScrollViews(
            in: root,
            visibleIn: viewport
        )

        #expect(visible.count == 2)
        #expect(visible.contains { $0 === first })
        #expect(visible.contains { $0 === second })
        #expect(!visible.contains { $0 === nested })
        #expect(!visible.contains { $0 === offscreen })

        let scrolled = ChatVisibleBubbleContentScroll.scrollVisibleScrollableContent(
            in: root,
            visibleIn: viewport,
            direction: .down,
            animated: false
        )

        #expect(scrolled == 2)
        #expect(first.contentOffset.y == ChatVisibleBubbleContentScroll.lineIncrement)
        #expect(second.contentOffset.y == ChatVisibleBubbleContentScroll.lineIncrement)
        #expect(nested.contentOffset.y == 0)
        #expect(offscreen.contentOffset.y == 0)
    }

    @Test("Cmd-J/K bubble content scroller uses a line increment instead of a page increment")
    @MainActor
    func bubbleContentScrollerUsesLineIncrementInsteadOfPageIncrement() {
        let viewport = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        let root = UIView(frame: viewport.bounds)
        viewport.addSubview(root)

        let scrollView = makeVerticalScrollView(frame: CGRect(x: 0, y: 0, width: 220, height: 200), contentHeight: 1_000)
        root.addSubview(scrollView)

        let scrolledDown = ChatVisibleBubbleContentScroll.scrollVisibleScrollableContent(
            in: root,
            visibleIn: viewport,
            direction: .down,
            animated: false
        )
        let pageIncrement = max(80, scrollView.bounds.height * 0.82)

        #expect(scrolledDown == 1)
        #expect(scrollView.contentOffset.y == ChatVisibleBubbleContentScroll.lineIncrement)
        #expect(scrollView.contentOffset.y < pageIncrement)

        let scrolledUp = ChatVisibleBubbleContentScroll.scrollVisibleScrollableContent(
            in: root,
            visibleIn: viewport,
            direction: .up,
            animated: false
        )

        #expect(scrolledUp == 1)
        #expect(scrollView.contentOffset.y == 0)
    }

    @Test("Scroll command responders post distinct bubble and chat notifications")
    @MainActor
    func scrollCommandRespondersPostDistinctBubbleAndChatNotifications() {
        let center = NotificationCenter.default
        let recorder = ScrollCommandNotificationRecorder()
        let names: [Notification.Name] = [
            .clawlineScrollDownCommand,
            .clawlineScrollUpCommand,
            .clawlineScrollChatDownCommand,
            .clawlineScrollChatUpCommand
        ]
        names.forEach { name in
            center.addObserver(
                recorder,
                selector: #selector(ScrollCommandNotificationRecorder.record(_:)),
                name: name,
                object: nil
            )
        }
        defer {
            center.removeObserver(recorder)
        }

        let responder = UIResponder()
        responder.clawlineScrollDownCommand(
            UIKeyCommand(
                input: "j",
                modifierFlags: [.command],
                action: #selector(UIResponder.clawlineScrollDownCommand(_:))
            )
        )
        responder.clawlineScrollUpCommand(
            UIKeyCommand(
                input: "k",
                modifierFlags: [.command],
                action: #selector(UIResponder.clawlineScrollUpCommand(_:))
            )
        )
        responder.clawlineScrollChatDownCommand(
            UIKeyCommand(
                input: "j",
                modifierFlags: [.command, .shift],
                action: #selector(UIResponder.clawlineScrollChatDownCommand(_:))
            )
        )
        responder.clawlineScrollChatUpCommand(
            UIKeyCommand(
                input: "k",
                modifierFlags: [.command, .shift],
                action: #selector(UIResponder.clawlineScrollChatUpCommand(_:))
            )
        )

        #expect(recorder.postedNames == [
            .clawlineScrollDownCommand,
            .clawlineScrollUpCommand,
            .clawlineScrollChatDownCommand,
            .clawlineScrollChatUpCommand
        ])
    }

    @Test("Notification number responders post menu reply and dismiss notifications")
    @MainActor
    func notificationNumberRespondersPostMenuReplyAndDismissNotifications() {
        let center = NotificationCenter.default
        var posted: [(Notification.Name, Int?)] = []
        let names: [Notification.Name] = [
            .clawlineOpenNotificationActionMenuCommand,
            .clawlineReplyNotificationCommand,
            .clawlineDismissNotificationCommand
        ]
        let tokens = names.map { name in
            center.addObserver(forName: name, object: nil, queue: nil) { notification in
                posted.append((name, notification.object as? Int))
            }
        }
        defer {
            tokens.forEach(center.removeObserver)
        }

        let responder = UIResponder()
        responder.clawlineNotificationNumberCommand(
            UIKeyCommand(
                input: "3",
                modifierFlags: [.command],
                action: #selector(UIResponder.clawlineNotificationNumberCommand(_:))
            )
        )
        responder.clawlineNotificationNumberCommand(
            UIKeyCommand(
                input: "3",
                modifierFlags: [.command, .shift],
                action: #selector(UIResponder.clawlineNotificationNumberCommand(_:))
            )
        )
        responder.clawlineNotificationNumberCommand(
            UIKeyCommand(
                input: "3",
                modifierFlags: [.command, .shift, .alternate],
                action: #selector(UIResponder.clawlineNotificationNumberCommand(_:))
            )
        )

        #expect(posted.map(\.0) == [
            .clawlineOpenNotificationActionMenuCommand,
            .clawlineReplyNotificationCommand,
            .clawlineDismissNotificationCommand
        ])
        #expect(posted.map(\.1) == [3, 3, 3])
    }

    @Test("No-text composed printable typing activates prompt insertion")
    func noTextComposedPrintableTypingActivatesPromptInsertion() {
        #expect(PromptFocusTypingActivation.promptInsertionText(from: "a") == "a")
        #expect(PromptFocusTypingActivation.promptInsertionText(from: "é") == "é")
        #expect(PromptFocusTypingActivation.promptInsertionText(from: "hello") == "hello")
    }

    @Test("No-text typing preserves existing slash, semicolon, space, return, and control key routes")
    func noTextTypingPreservesExistingShortcutAndControlRoutes() {
        #expect(PromptFocusTypingActivation.promptInsertionText(from: "/") == nil)
        #expect(PromptFocusTypingActivation.promptInsertionText(from: ";") == nil)
        #expect(PromptFocusTypingActivation.promptInsertionText(from: " ") == nil)
        #expect(PromptFocusTypingActivation.promptInsertionText(from: "\r") == nil)
        #expect(PromptFocusTypingActivation.promptInsertionText(from: "\n") == nil)
        #expect(PromptFocusTypingActivation.promptInsertionText(from: "\t") == nil)
        #expect(PromptFocusTypingActivation.promptInsertionText(from: "") == nil)
    }

    @Test("Keyboard bubble scroll shortcuts only enable when chat content can receive commands")
    func keyboardBubbleScrollShortcutsOnlyEnableWhenChatContentCanReceiveCommands() {
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

    @Test("Visible notifications own Cmd-J/K and Cmd-Shift-J/K before text-field focus blocks")
    @MainActor
    func visibleNotificationsOwnScrollShortcutsBeforeTextFieldFocusBlocks() {
        #expect(
            ChatKeyboardScrollRouting.route(
                command: .scrollDown,
                isEnabled: true,
                hasVisibleNotifications: true,
                firstResponderBlocksKeyboardScroll: true
            ) == .notificationDown
        )
        #expect(
            ChatKeyboardScrollRouting.route(
                command: .scrollUp,
                isEnabled: true,
                hasVisibleNotifications: true,
                firstResponderBlocksKeyboardScroll: true
            ) == .notificationUp
        )
        #expect(
            ChatKeyboardScrollRouting.route(
                command: .scrollChatDown,
                isEnabled: true,
                hasVisibleNotifications: true,
                firstResponderBlocksKeyboardScroll: true
            ) == .notificationDown
        )
        #expect(
            ChatKeyboardScrollRouting.route(
                command: .scrollChatUp,
                isEnabled: true,
                hasVisibleNotifications: true,
                firstResponderBlocksKeyboardScroll: true
            ) == .notificationUp
        )
    }

    @Test("Notification reply field keeps notification number and scroll shortcuts above text focus")
    @MainActor
    func notificationReplyFieldKeepsNotificationNumberAndScrollShortcutsAboveTextFocus() {
        #expect(
            CrossChatNotificationKeyPrecedence.replyFieldAction(
                characters: "3",
                modifiers: .command,
                visibleNotificationCount: 4
            ) == .openMenu(3)
        )
        #expect(
            CrossChatNotificationKeyPrecedence.replyFieldAction(
                characters: "#",
                modifiers: [.command, .shift],
                visibleNotificationCount: 4
            ) == .reply(3)
        )
        #expect(
            CrossChatNotificationKeyPrecedence.replyFieldAction(
                characters: "#",
                modifiers: [.command, .shift, .option],
                visibleNotificationCount: 4
            ) == .dismiss(3)
        )
        #expect(
            CrossChatNotificationKeyPrecedence.replyFieldAction(
                characters: "1",
                modifiers: .command,
                visibleNotificationCount: 4
            ) == .openMenu(1)
        )
        #expect(
            CrossChatNotificationKeyPrecedence.replyFieldAction(
                characters: "j",
                modifiers: .command,
                visibleNotificationCount: 4
            ) == .scrollDown
        )
        #expect(
            CrossChatNotificationKeyPrecedence.replyFieldAction(
                characters: "k",
                modifiers: [.command, .shift],
                visibleNotificationCount: 4
            ) == .scrollUp
        )
        #expect(
            CrossChatNotificationKeyPrecedence.replyFieldAction(
                characters: "3",
                modifiers: [.command, .control],
                visibleNotificationCount: 4
            ) == nil
        )
        #expect(
            CrossChatNotificationKeyPrecedence.replyFieldAction(
                characters: "4",
                modifiers: .command,
                visibleNotificationCount: 4
            ) == nil
        )
    }

    @Test("Transcript and chat scroll receive only unclaimed scroll shortcuts")
    @MainActor
    func transcriptAndChatScrollReceiveOnlyUnclaimedScrollShortcuts() {
        #expect(
            ChatKeyboardScrollRouting.route(
                command: .scrollDown,
                isEnabled: true,
                hasVisibleNotifications: false,
                firstResponderBlocksKeyboardScroll: false
            ) == .bubbleDown
        )
        #expect(
            ChatKeyboardScrollRouting.route(
                command: .scrollChatDown,
                isEnabled: true,
                hasVisibleNotifications: false,
                firstResponderBlocksKeyboardScroll: false
            ) == .chatDown
        )
        #expect(
            ChatKeyboardScrollRouting.route(
                command: .scrollDown,
                isEnabled: true,
                hasVisibleNotifications: false,
                firstResponderBlocksKeyboardScroll: true
            ) == .none
        )
        #expect(
            ChatKeyboardScrollRouting.route(
                command: .scrollChatDown,
                isEnabled: true,
                hasVisibleNotifications: false,
                firstResponderBlocksKeyboardScroll: true
            ) == .none
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

private func makeVerticalScrollView(frame: CGRect, contentHeight: CGFloat) -> UIScrollView {
    let scrollView = UIScrollView(frame: frame)
    scrollView.isScrollEnabled = true
    scrollView.contentSize = CGSize(width: frame.width, height: contentHeight)
    return scrollView
}

private final class ScrollCommandNotificationRecorder: NSObject {
    var postedNames: [Notification.Name] = []

    @objc func record(_ notification: Notification) {
        postedNames.append(notification.name)
    }
}
