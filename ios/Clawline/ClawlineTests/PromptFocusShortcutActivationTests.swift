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
    @Test("T307 accent reply gesture only accepts vertical-dominant swipes")
    func accentReplyGestureOnlyAcceptsVerticalDominantSwipes() {
        #expect(
            CrossChatNotificationAccentReplyGesture.shouldToggleReply(
                translation: CGSize(width: 0, height: CrossChatNotificationAccentReplyGesture.minimumDistance)
            )
        )
        #expect(
            CrossChatNotificationAccentReplyGesture.shouldToggleReply(
                translation: CGSize(width: 4, height: -32)
            )
        )
        #expect(
            CrossChatNotificationAccentReplyGesture.shouldToggleReply(
                translation: CGSize(width: 28, height: 10)
            ) == false
        )
        #expect(
            CrossChatNotificationAccentReplyGesture.shouldToggleReply(
                translation: CGSize(width: 0, height: CrossChatNotificationAccentReplyGesture.minimumDistance - 1)
            ) == false
        )
        #expect(
            CrossChatNotificationAccentReplyGesture.shouldToggleReply(
                translation: CGSize(width: 24, height: 24)
            ) == false
        )
    }

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
        textView.returnKeyType = .default
        textView.enforceSendReturnKey()
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
            ChatAppCommandShortcut.notificationScrollKeyCommandSpecs(notificationVisibleCount: 0).map(\.action) == [
                .scrollDown,
                .scrollUp,
                .scrollChatDown,
                .scrollChatUp
            ]
        )
        #expect(
            ChatAppCommandShortcut.notificationScrollKeyCommandSpecs(notificationVisibleCount: 2).map(\.action) == [
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

    @Test("Prompt text input exposes notification scroll commands before base text-view commands")
    @MainActor
    func promptTextInputExposesNotificationScrollCommandsBeforeBaseTextViewCommands() {
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

    @Test("Text input bridge exposure follows router notification ownership")
    @MainActor
    func textInputBridgeExposureFollowsRouterNotificationOwnership() {
        let transcriptOnlyStore = KeyboardOwnershipSceneFactory.chatScene(
            visibleNotificationSourceChatIds: [],
            mentionPickerVisible: false,
            composerFocused: true,
            notificationReplyFocusedSourceChatId: nil,
            actionMenuSourceChatId: nil
        )
        let notificationStore = KeyboardOwnershipSceneFactory.chatScene(
            visibleNotificationSourceChatIds: ["notification-0", "notification-1"],
            mentionPickerVisible: false,
            composerFocused: true,
            notificationReplyFocusedSourceChatId: nil,
            actionMenuSourceChatId: nil
        )
        #expect(KeyboardCommandRouter.route(intent: .transcriptBubbleScrollForward, store: transcriptOnlyStore).outcome == .ignored)
        assertRoute(.transcriptBubbleScrollForward, in: notificationStore, isHandledBy: .notificationBubble("notification-0"), rule: "PR-04")
        assertRoute(.transcriptChatScrollBackward, in: notificationStore, isHandledBy: .notificationBubble("notification-0"), rule: "PR-04")
        assertRoute(.notificationAssignedDismiss(1), in: notificationStore, isHandledBy: .notificationBubble("notification-1"), rule: "PR-03")
        assertRoute(.focusPromptInput, in: notificationStore, isHandledBy: .transcript, rule: "PR-07")
        #expect(KeyboardCommandBridge.intent(input: "1", modifierFlags: [.command, .control]) == nil)
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

    @Test("Scroll command responders post distinct normalized router intents")
    @MainActor
    func scrollCommandRespondersPostDistinctBubbleAndChatNotifications() {
        let center = NotificationCenter.default
        var posted: [KeyboardCommandIntent] = []
        let token = center.addObserver(forName: .clawlineKeyboardCommandIntent, object: nil, queue: nil) { notification in
            if let intent = notification.object as? KeyboardCommandIntent {
                posted.append(intent)
            }
        }
        defer {
            center.removeObserver(token)
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

        #expect(posted == [
            .transcriptBubbleScrollForward,
            .transcriptBubbleScrollBackward,
            .transcriptChatScrollForward,
            .transcriptChatScrollBackward
        ])
    }

    @Test("Notification number responder posts normalized router intents")
    @MainActor
    func notificationNumberResponderPostsNormalizedRouterIntents() {
        let center = NotificationCenter.default
        var posted: [KeyboardCommandIntent] = []
        let token = center.addObserver(forName: .clawlineKeyboardCommandIntent, object: nil, queue: nil) { notification in
            if let intent = notification.object as? KeyboardCommandIntent {
                posted.append(intent)
            }
        }
        defer {
            center.removeObserver(token)
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

        #expect(posted == [
            .notificationAssignedOpen(3),
            .notificationAssignedReply(3),
            .notificationAssignedDismiss(3)
        ])
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

    @Test("Visible notifications own Cmd-J/K and Cmd-Shift-J/K before text-field focus blocks")
    @MainActor
    func visibleNotificationsOwnScrollShortcutsBeforeTextFieldFocusBlocks() {
        let store = KeyboardOwnershipSceneFactory.chatScene(
            visibleNotificationSourceChatIds: ["notification-0"],
            mentionPickerVisible: false,
            composerFocused: true,
            notificationReplyFocusedSourceChatId: nil,
            actionMenuSourceChatId: nil
        )
        assertRoute(.transcriptBubbleScrollForward, in: store, isHandledBy: .notificationBubble("notification-0"), rule: "PR-04")
        assertRoute(.transcriptBubbleScrollBackward, in: store, isHandledBy: .notificationBubble("notification-0"), rule: "PR-04")
        assertRoute(.transcriptChatScrollForward, in: store, isHandledBy: .notificationBubble("notification-0"), rule: "PR-04")
        assertRoute(.transcriptChatScrollBackward, in: store, isHandledBy: .notificationBubble("notification-0"), rule: "PR-04")
    }

    @Test("Visible notifications expose global scroll shortcuts outside focused command ownership")
    func visibleNotificationsExposeGlobalScrollShortcutsOutsideFocusedCommandOwnership() {
        #expect(CrossChatNotificationGlobalShortcut.scrollSpecs(visibleNotificationCount: 0).isEmpty)
        #expect(
            CrossChatNotificationGlobalShortcut.scrollSpecs(visibleNotificationCount: 2) == [
                .init(input: "j", modifiers: .command, action: .scrollDown),
                .init(input: "k", modifiers: .command, action: .scrollUp),
                .init(input: "j", modifiers: [.command, .shift], action: .scrollDown),
                .init(input: "k", modifiers: [.command, .shift], action: .scrollUp),
            ]
        )
    }

    @Test("Notification reply field keeps notification number and scroll shortcuts above text focus")
    @MainActor
    func notificationReplyFieldKeepsNotificationNumberAndScrollShortcutsAboveTextFocus() {
        let store = KeyboardOwnershipSceneFactory.chatScene(
            visibleNotificationSourceChatIds: ["notification-0", "notification-1", "notification-2", "notification-3"],
            mentionPickerVisible: false,
            composerFocused: false,
            notificationReplySourceChatIds: ["notification-0"],
            notificationReplyFocusedSourceChatId: "notification-0",
            actionMenuSourceChatId: nil
        )
        assertRoute(.notificationAssignedOpen(3), in: store, isHandledBy: .notificationBubble("notification-3"), rule: "PR-03")
        assertRoute(.notificationAssignedReply(3), in: store, isHandledBy: .notificationBubble("notification-3"), rule: "PR-03")
        assertRoute(.notificationAssignedDismiss(3), in: store, isHandledBy: .notificationBubble("notification-3"), rule: "PR-03")
        assertRoute(.notificationAssignedOpen(1), in: store, isHandledBy: .notificationBubble("notification-1"), rule: "PR-03")
        assertRoute(.notificationScrollForward, in: store, isHandledBy: .notificationBubble("notification-0"), rule: "PR-04")
        assertRoute(.notificationScrollBackward, in: store, isHandledBy: .notificationBubble("notification-0"), rule: "PR-04")
        #expect(KeyboardCommandBridge.intent(input: "3", modifierFlags: [.command, .control]) == nil)
        #expect(KeyboardCommandRouter.route(intent: .notificationAssignedOpen(4), store: store).outcome == .fallthroughToDefault)
    }

    @Test("Transcript and chat scroll receive only unclaimed scroll shortcuts")
    @MainActor
    func transcriptAndChatScrollReceiveOnlyUnclaimedScrollShortcuts() {
        let transcriptStore = KeyboardOwnershipSceneFactory.chatScene(
            visibleNotificationSourceChatIds: [],
            mentionPickerVisible: false,
            composerFocused: false,
            notificationReplyFocusedSourceChatId: nil,
            actionMenuSourceChatId: nil
        )
        let composerFocusedStore = KeyboardOwnershipSceneFactory.chatScene(
            visibleNotificationSourceChatIds: [],
            mentionPickerVisible: false,
            composerFocused: true,
            notificationReplyFocusedSourceChatId: nil,
            actionMenuSourceChatId: nil
        )
        assertRoute(.transcriptBubbleScrollForward, in: transcriptStore, isHandledBy: .transcript, rule: "PR-07")
        assertRoute(.transcriptChatScrollForward, in: transcriptStore, isHandledBy: .transcript, rule: "PR-07")
        #expect(KeyboardCommandRouter.route(intent: .transcriptBubbleScrollForward, store: composerFocusedStore).outcome == .ignored)
        #expect(KeyboardCommandRouter.route(intent: .transcriptChatScrollForward, store: composerFocusedStore).outcome == .ignored)
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
}

private final class ScrollCommandNotificationRecorder: NSObject {
    var postedNames: [Notification.Name] = []

    @objc func record(_ notification: Notification) {
        postedNames.append(notification.name)
    }
}
