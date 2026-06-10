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

    @Test("T344 notification gesture ownership locks to vertical scroll only after vertical dominance")
    func notificationGestureOwnershipLocksToVerticalScrollOnlyAfterVerticalDominance() {
        #expect(
            CrossChatNotificationGestureAxisLock.ownership(
                for: CGSize(width: 0, height: CrossChatNotificationGestureAxisLock.minimumDistance)
            ) == .verticalScroll
        )
        #expect(
            CrossChatNotificationGestureAxisLock.ownership(
                for: CGSize(width: 8, height: -32)
            ) == .verticalScroll
        )
        #expect(
            CrossChatNotificationGestureAxisLock.ownership(
                for: CGSize(width: 24, height: 24)
            ) == .none
        )
        #expect(
            CrossChatNotificationGestureAxisLock.ownership(
                for: CGSize(width: 0, height: CrossChatNotificationGestureAxisLock.minimumDistance - 1)
            ) == .none
        )
    }

    @Test("T344 notification gesture ownership locks to horizontal swipe only after horizontal dominance")
    func notificationGestureOwnershipLocksToHorizontalSwipeOnlyAfterHorizontalDominance() {
        #expect(
            CrossChatNotificationGestureAxisLock.ownership(
                for: CGSize(width: CrossChatNotificationGestureAxisLock.minimumDistance, height: 0)
            ) == .horizontalSwipe
        )
        #expect(
            CrossChatNotificationGestureAxisLock.ownership(
                for: CGSize(width: -40, height: 12)
            ) == .horizontalSwipe
        )
        #expect(
            CrossChatNotificationGestureAxisLock.ownership(
                for: CGSize(width: 18, height: 2)
            ) == .none
        )
        #expect(
            CrossChatNotificationGestureAxisLock.ownership(
                for: CGSize(width: 28, height: 36)
            ) != .horizontalSwipe
        )
    }

    @Test("T344 vertical-owned notification drag cannot complete as horizontal dock or dismiss")
    func verticalOwnedNotificationDragCannotCompleteAsHorizontalDockOrDismiss() {
        let threshold: CGFloat = 44

        #expect(
            CrossChatNotificationGestureAxisLock.allowsBubbleSwipeCompletion(
                activeLock: .verticalScroll,
                finalTranslation: CGSize(width: threshold + 20, height: 24),
                completionThreshold: threshold
            ) == false
        )
        #expect(
            CrossChatNotificationGestureAxisLock.allowsBubbleSwipeCompletion(
                activeLock: .horizontalSwipe,
                finalTranslation: CGSize(width: -(threshold + 20), height: 12),
                completionThreshold: threshold
            )
        )
        #expect(
            CrossChatNotificationGestureAxisLock.allowsBubbleSwipeCompletion(
                activeLock: nil,
                finalTranslation: CGSize(width: threshold + 20, height: 12),
                completionThreshold: threshold
            )
        )
        #expect(
            CrossChatNotificationGestureAxisLock.allowsBubbleSwipeCompletion(
                activeLock: nil,
                finalTranslation: CGSize(width: threshold - 1, height: 4),
                completionThreshold: threshold
            ) == false
        )
    }

    @Test("T1250 text selection suppresses notification left and right swipe completion")
    @MainActor
    func textSelectionSuppressesNotificationLeftAndRightSwipeCompletion() {
        let threshold: CGFloat = 44

        #expect(CrossChatNotificationSelectionSwipeSuppression.allowsSwipe(isTextSelectionActive: true) == false)
        #expect(
            CrossChatNotificationGestureAxisLock.allowsBubbleSwipeCompletion(
                activeLock: .horizontalSwipe,
                finalTranslation: CGSize(width: threshold + 20, height: 4),
                completionThreshold: threshold,
                isTextSelectionActive: true
            ) == false
        )
        #expect(
            CrossChatNotificationGestureAxisLock.allowsBubbleSwipeCompletion(
                activeLock: .horizontalSwipe,
                finalTranslation: CGSize(width: -(threshold + 20), height: 4),
                completionThreshold: threshold,
                isTextSelectionActive: true
            ) == false
        )
        #expect(
            CrossChatNotificationBubbleSwipeCompletion.effect(
                activeLock: .horizontalSwipe,
                finalTranslation: CGSize(width: threshold + 20, height: 4),
                completionThreshold: threshold,
                isDocked: false,
                isTextSelectionActive: true
            ) == nil
        )
        #expect(
            CrossChatNotificationBubbleSwipeCompletion.effect(
                activeLock: .horizontalSwipe,
                finalTranslation: CGSize(width: -(threshold + 20), height: 4),
                completionThreshold: threshold,
                isDocked: false,
                isTextSelectionActive: true
            ) == nil
        )
    }

    @Test("T1250 inactive selection preserves normal notification swipes")
    @MainActor
    func inactiveSelectionPreservesNormalNotificationSwipes() {
        let threshold: CGFloat = 44

        #expect(CrossChatNotificationSelectionSwipeSuppression.allowsSwipe(isTextSelectionActive: false))
        #expect(
            CrossChatNotificationBubbleSwipeCompletion.effect(
                activeLock: .horizontalSwipe,
                finalTranslation: CGSize(width: threshold + 20, height: 4),
                completionThreshold: threshold,
                isDocked: false,
                isTextSelectionActive: false
            ) == .dock
        )
        #expect(
            CrossChatNotificationBubbleSwipeCompletion.effect(
                activeLock: .horizontalSwipe,
                finalTranslation: CGSize(width: -(threshold + 20), height: 4),
                completionThreshold: threshold,
                isDocked: false,
                isTextSelectionActive: false
            ) == .dismiss
        )
    }

    @Test("T1250 multiple notification content selections aggregate before re-enabling swipes")
    @MainActor
    func multipleNotificationContentSelectionsAggregateBeforeReenablingSwipes() {
        var state = CrossChatNotificationTextSelectionState()

        state.setContentSelectionActive(true, key: "entry-a:0")
        state.setContentSelectionActive(true, key: "entry-b:0")
        #expect(state.isAnySelectionActive)

        state.setContentSelectionActive(false, key: "entry-a:0")
        #expect(state.isAnySelectionActive)

        state.setContentSelectionActive(false, key: "entry-b:0")
        #expect(state.isAnySelectionActive == false)
    }

    @Test("T1250 replacing notification content clears stale content selection")
    @MainActor
    func replacingNotificationContentClearsStaleContentSelection() {
        var state = CrossChatNotificationTextSelectionState()

        state.setContentSelectionActive(true, key: "entry-a:0")
        #expect(state.isAnySelectionActive)

        state.clearContentSelection()
        #expect(state.isAnySelectionActive == false)
    }

    @Test("T1250 same-length notification content replacement changes selection cleanup key")
    @MainActor
    func sameLengthNotificationContentReplacementChangesSelectionCleanupKey() {
        let original = [
            CrossChatAssistantNotificationEntry(id: "entry-a", content: "abcd", timestamp: Date(timeIntervalSince1970: 1))
        ]
        let replacement = [
            CrossChatAssistantNotificationEntry(id: "entry-a", content: "wxyz", timestamp: Date(timeIntervalSince1970: 1))
        ]

        #expect(CrossChatNotificationEntriesAnimationKey.value(for: original) != CrossChatNotificationEntriesAnimationKey.value(for: replacement))
    }

    @Test("T1250 reply composer selection keeps swipes suppressed after content selection clears")
    @MainActor
    func replyComposerSelectionKeepsSwipesSuppressedAfterContentSelectionClears() {
        var state = CrossChatNotificationTextSelectionState()

        state.setContentSelectionActive(true, key: "entry-a:0")
        state.setReplySelectionActive(true)
        state.setContentSelectionActive(false, key: "entry-a:0")

        #expect(state.isAnySelectionActive)

        state.setReplySelectionActive(false)
        #expect(state.isAnySelectionActive == false)
    }

    @Test("T355 docked notification left swipe restores stack instead of dismissing")
    @MainActor
    func dockedNotificationLeftSwipeRestoresStackInsteadOfDismissing() {
        let dockedLeftSwipe = CrossChatNotificationBubbleSwipeCompletion.effect(
            activeLock: .horizontalSwipe,
            finalTranslation: CGSize(width: -64, height: 4),
            completionThreshold: 44,
            isDocked: true
        )

        #expect(dockedLeftSwipe == .restoreDock)
        #expect(dockedLeftSwipe?.restoresDock == true)
        #expect(dockedLeftSwipe?.dismissesNotification == false)
        #expect(
            CrossChatNotificationBubbleSwipeCompletion.effect(
                activeLock: .verticalScroll,
                finalTranslation: CGSize(width: -64, height: 4),
                completionThreshold: 44,
                isDocked: true
            ) == nil
        )
        #expect(
            CrossChatNotificationBubbleSwipeCompletion.effect(
                activeLock: .horizontalSwipe,
                finalTranslation: CGSize(width: -64, height: 4),
                completionThreshold: 44,
                isDocked: false
            ) == .dismiss
        )
    }

    @Test("T1150 peeking dock-bound notification left swipe does not dismiss")
    @MainActor
    func peekingDockBoundNotificationLeftSwipeDoesNotDismiss() {
        let peekingLeftSwipe = CrossChatNotificationBubbleSwipeCompletion.effect(
            activeLock: .horizontalSwipe,
            finalTranslation: CGSize(width: -64, height: 4),
            completionThreshold: 44,
            isDocked: true
        )

        #expect(peekingLeftSwipe == .restoreDock)
        #expect(peekingLeftSwipe?.dismissesNotification == false)
    }

    @Test("T355 notification right swipe preserves dock and collapsed preview behavior")
    @MainActor
    func notificationRightSwipePreservesDockAndCollapsedPreviewBehavior() {
        #expect(
            CrossChatNotificationBubbleSwipeCompletion.effect(
                activeLock: .horizontalSwipe,
                finalTranslation: CGSize(width: 64, height: 4),
                completionThreshold: 44,
                isDocked: false
            ) == .dock
        )
        #expect(
            CrossChatNotificationBubbleSwipeCompletion.effect(
                activeLock: .horizontalSwipe,
                finalTranslation: CGSize(width: 64, height: 4),
                completionThreshold: 44,
                isDocked: true
            ) == .clearCollapsedPreview
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

    @Test("T342 main prompt input exposes modified Return newline hardware shortcuts")
    @MainActor
    func mainPromptInputExposesModifiedReturnNewlineHardwareShortcuts() {
        let textView = PastableTextView(frame: .zero, textContainer: nil)

        assertModifiedReturnCommands(
            in: textView.keyCommands,
            action: Selector(("didPressModifiedReturn:"))
        )
        #expect(
            textView.keyCommands?.contains { command in
                (command.input == "\r" || command.input == "\n")
                    && command.modifierFlags.isEmpty
                    && command.action == Selector(("didPressModifiedReturn:"))
            } == false
        )
    }

    @Test("T342 main prompt modified Return inserts newline at caret")
    @MainActor
    func mainPromptModifiedReturnInsertsNewlineAtCaret() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 120))
        let textView = PastableTextView(frame: CGRect(x: 0, y: 0, width: 320, height: 44), textContainer: nil)
        textView.keyboardOwnershipStore = KeyboardOwnershipSceneFactory.chatScene(
            visibleNotificationSourceChatIds: [],
            mentionPickerVisible: false,
            composerFocused: true,
            notificationReplyFocusedSourceChatId: nil,
            actionMenuSourceChatId: nil
        )
        window.addSubview(textView)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        textView.text = "abcd"
        textView.selectedRange = NSRange(location: 2, length: 0)
        #expect(textView.becomeFirstResponder())

        textView.perform(
            Selector(("didPressModifiedReturn:")),
            with: UIKeyCommand(input: "\r", modifierFlags: [.control], action: Selector(("didPressModifiedReturn:")))
        )
        #expect(textView.text == "ab\ncd")
        #expect(textView.selectedRange == NSRange(location: 3, length: 0))

        textView.perform(
            Selector(("didPressModifiedReturn:")),
            with: UIKeyCommand(input: "\n", modifierFlags: [.shift], action: Selector(("didPressModifiedReturn:")))
        )
        #expect(textView.text == "ab\n\ncd")
        #expect(textView.selectedRange == NSRange(location: 4, length: 0))
    }

    @Test("T342 reply input exposes modified Return newline hardware shortcuts")
    @MainActor
    func replyInputExposesModifiedReturnNewlineHardwareShortcuts() {
        let textView = NotificationReplyUITextView()

        assertModifiedReturnCommands(
            in: textView.keyCommands,
            action: Selector(("didPressModifiedReturn:"))
        )
        #expect(
            textView.keyCommands?.contains { command in
                (command.input == "\r" || command.input == "\n")
                    && command.modifierFlags.isEmpty
                    && command.action == Selector(("didPressModifiedReturn:"))
            } == false
        )
    }

    @Test("T342 reply input modified Return inserts newline at caret")
    @MainActor
    func replyInputModifiedReturnInsertsNewlineAtCaret() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 120))
        let textView = NotificationReplyUITextView(frame: CGRect(x: 0, y: 0, width: 320, height: 44), textContainer: nil)
        let sourceChatId = "reply-source"
        textView.sourceChatId = sourceChatId
        textView.keyboardOwnershipStore = KeyboardOwnershipSceneFactory.chatScene(
            visibleNotificationSourceChatIds: [sourceChatId],
            mentionPickerVisible: false,
            composerFocused: false,
            notificationReplySourceChatIds: [sourceChatId],
            notificationReplyFocusedSourceChatId: sourceChatId,
            actionMenuSourceChatId: nil
        )
        window.addSubview(textView)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        textView.text = "reply"
        textView.selectedRange = NSRange(location: 2, length: 0)
        #expect(textView.becomeFirstResponder())

        textView.perform(
            Selector(("didPressModifiedReturn:")),
            with: UIKeyCommand(input: "\r", modifierFlags: [.control], action: Selector(("didPressModifiedReturn:")))
        )
        #expect(textView.text == "re\nply")
        #expect(textView.selectedRange == NSRange(location: 3, length: 0))

        textView.perform(
            Selector(("didPressModifiedReturn:")),
            with: UIKeyCommand(input: "\n", modifierFlags: [.shift], action: Selector(("didPressModifiedReturn:")))
        )
        #expect(textView.text == "re\n\nply")
        #expect(textView.selectedRange == NSRange(location: 4, length: 0))
    }

    @Test("T342 main prompt software Return delegate path stays submit because Shift-Return is not distinguishable")
    @MainActor
    func mainPromptSoftwareReturnDelegatePathStaysSubmitBecauseShiftReturnIsNotDistinguishable() {
        var attributedText = NSAttributedString(string: "draft")
        var calculatedHeight: CGFloat = 44
        var selectionRange = NSRange(location: 0, length: 0)
        var pendingInsertions: [PendingAttachment] = []
        var submitCount = 0
        let editor = RichTextEditor(
            attributedText: Binding(get: { attributedText }, set: { attributedText = $0 }),
            calculatedHeight: Binding(get: { calculatedHeight }, set: { calculatedHeight = $0 }),
            selectionRange: Binding(get: { selectionRange }, set: { selectionRange = $0 }),
            pendingInsertions: Binding(get: { pendingInsertions }, set: { pendingInsertions = $0 }),
            fontScaleChangeSequence: 0,
            resetToken: 0,
            focusTrigger: 0,
            isEditable: true,
            tintColor: .systemBlue,
            onFocusChange: { _ in },
            onSubmit: { submitCount += 1 },
            notificationVisibleCount: 0,
            keyboardOwnershipStore: KeyboardOwnershipSceneFactory.chatScene(
                visibleNotificationSourceChatIds: [],
                mentionPickerVisible: false,
                composerFocused: true,
                notificationReplyFocusedSourceChatId: nil,
                actionMenuSourceChatId: nil
            )
        )
        let coordinator = RichTextEditor.Coordinator(parent: editor)
        let textView = UITextView()
        textView.text = "draft"

        let shouldChange = coordinator.textView(
            textView,
            shouldChangeTextIn: NSRange(location: 5, length: 0),
            replacementText: "\n"
        )

        #expect(!shouldChange)
        #expect(submitCount == 1)
        #expect(textView.text == "draft")
    }

    @Test("T342 reply software Return delegate path stays submit because Shift-Return is not distinguishable")
    @MainActor
    func replySoftwareReturnDelegatePathStaysSubmitBecauseShiftReturnIsNotDistinguishable() {
        var text = "reply"
        var measuredHeight: CGFloat = 20
        var submitCount = 0
        let sourceChatId = "reply-source"
        let keyboardOwnershipStore = KeyboardOwnershipSceneFactory.chatScene(
            visibleNotificationSourceChatIds: [sourceChatId],
            mentionPickerVisible: false,
            composerFocused: false,
            notificationReplySourceChatIds: [sourceChatId],
            notificationReplyFocusedSourceChatId: sourceChatId,
            actionMenuSourceChatId: nil
        )
        let input = NotificationReplyTextInput(
            sourceChatId: sourceChatId,
            text: Binding(get: { text }, set: { text = $0 }),
            measuredHeight: Binding(get: { measuredHeight }, set: { measuredHeight = $0 }),
            font: UIFont.systemFont(ofSize: 15),
            textColor: .label,
            tintColor: .systemBlue,
            visibleNotificationCount: 0,
            keyboardOwnershipStore: keyboardOwnershipStore,
            onSubmit: { submitCount += 1 },
            onCancel: {},
            onFocusChange: { _ in },
            onSelectionChange: { _ in }
        )
        let coordinator = NotificationReplyTextInput.Coordinator(parent: input)
        let textView = UITextView()
        textView.text = "reply"

        let shouldChange = coordinator.textView(
            textView,
            shouldChangeTextIn: NSRange(location: 5, length: 0),
            replacementText: "\n"
        )

        #expect(!shouldChange)
        #expect(submitCount == 1)
        #expect(textView.text == "reply")
    }

    @Test("T1250 notification reply composer reports active text selection")
    @MainActor
    func notificationReplyComposerReportsActiveTextSelection() {
        var text = "selectable reply"
        var measuredHeight: CGFloat = 20
        var selectionStates: [Bool] = []
        let input = NotificationReplyTextInput(
            sourceChatId: "reply-source",
            text: Binding(get: { text }, set: { text = $0 }),
            measuredHeight: Binding(get: { measuredHeight }, set: { measuredHeight = $0 }),
            font: UIFont.systemFont(ofSize: 15),
            textColor: .label,
            tintColor: .systemBlue,
            visibleNotificationCount: 1,
            onSubmit: {},
            onCancel: {},
            onFocusChange: { _ in },
            onSelectionChange: { selectionStates.append($0) }
        )
        let coordinator = NotificationReplyTextInput.Coordinator(parent: input)
        let textView = UITextView()
        textView.text = text

        textView.selectedRange = NSRange(location: 0, length: 6)
        coordinator.textViewDidChangeSelection(textView)
        textView.selectedRange = NSRange(location: 6, length: 0)
        coordinator.textViewDidChangeSelection(textView)
        textView.selectedRange = NSRange(location: 0, length: 4)
        coordinator.textViewDidChangeSelection(textView)
        coordinator.textViewDidEndEditing(textView)

        #expect(selectionStates == [true, false, true, false])
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

    @Test("App command shortcuts use Cmd-L focus, Cmd-semicolon streams, Cmd-Shift navigation, Cmd-J/K bubble scroll, and Cmd-Shift-J/K chat scroll")
    func appCommandShortcutsUseCommandLFocusCommandSemicolonStreamsCommandShiftNavigationCommandJKBubbleScrollAndCommandShiftJKChatScroll() {
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
                spec.input == ";"
                    && spec.modifierFlags == [.control]
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
                    && spec.modifierFlags == [.command, .alternate]
                    && spec.action.selector == #selector(UIResponder.clawlineNotificationNumberCommand(_:))
            })
            #expect(!notificationCommandSpecs.contains { spec in
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
                .scrollNotificationDown,
                .scrollNotificationUp
            ]
        )
        #expect(
            ChatAppCommandShortcut.notificationScrollKeyCommandSpecs(notificationVisibleCount: 2).map(\.action) == [
                .scrollNotificationDown,
                .scrollNotificationUp
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

    @Test("Prompt text input exposes Cmd-J/K fan-out commands before base text-view commands")
    @MainActor
    func promptTextInputExposesFanOutScrollCommandsBeforeBaseTextViewCommands() {
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

    @Test("Prompt text input exposes Cmd-semicolon stream popup before base text-view commands")
    @MainActor
    func promptTextInputExposesCommandSemicolonStreamPopupBeforeBaseTextViewCommands() {
        let textView = PastableTextView(frame: .zero, textContainer: nil)
        textView.notificationVisibleCount = 0

        let firstCommandSemicolon = textView.keyCommands?.first { command in
            command.input == ";" && command.modifierFlags == [.command]
        }
        let firstControlSemicolon = textView.keyCommands?.first { command in
            command.input == ";" && command.modifierFlags == [.control]
        }

        #expect(firstCommandSemicolon?.action == #selector(UIResponder.clawlineOpenStreamPopupCommand(_:)))
        #expect(firstControlSemicolon?.action == #selector(UIResponder.clawlineOpenStreamPopupCommand(_:)))
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
        assertRoute(.transcriptBubbleScrollForward, in: transcriptOnlyStore, isHandledBy: .transcript, rule: "PR-07")
        assertRoute(.transcriptBubbleScrollForward, in: notificationStore, isHandledBy: .transcript, rule: "PR-04")
        assertRoute(.transcriptBubbleScrollForward, in: notificationStore, isHandledBy: .notificationBubble("notification-0"), rule: "PR-04")
        assertRoute(.transcriptChatScrollBackward, in: notificationStore, isHandledBy: .transcript, rule: "PR-07")
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
                modifierFlags: [.command, .alternate],
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

        posted.removeAll()
        responder.clawlineNotificationNumberCommand(
            UIKeyCommand(
                input: "3",
                modifierFlags: [.command, .shift],
                action: #selector(UIResponder.clawlineNotificationNumberCommand(_:))
            )
        )
        responder.clawlineNotificationNumberCommand(
            UIKeyCommand(
                input: "#",
                modifierFlags: [.command, .shift],
                action: #selector(UIResponder.clawlineNotificationNumberCommand(_:))
            )
        )
        #expect(posted.isEmpty)
    }

    @Test("Notification scroll responders normalize physical Cmd-J/K through root fan-out intents")
    @MainActor
    func notificationScrollRespondersPostNotificationScrollIntents() {
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
        responder.clawlineScrollNotificationDownCommand(
            UIKeyCommand(
                input: "j",
                modifierFlags: [.command],
                action: #selector(UIResponder.clawlineScrollNotificationDownCommand(_:))
            )
        )
        responder.clawlineScrollNotificationUpCommand(
            UIKeyCommand(
                input: "k",
                modifierFlags: [.command],
                action: #selector(UIResponder.clawlineScrollNotificationUpCommand(_:))
            )
        )

        #expect(posted == [
            .transcriptBubbleScrollForward,
            .transcriptBubbleScrollBackward
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

    @Test("Visible notifications keep Cmd-J/K fan-out while Cmd-Shift-J/K remains transcript-owned")
    @MainActor
    func visibleNotificationsKeepCommandJFanoutAndCommandShiftTranscriptOwnership() {
        let store = KeyboardOwnershipSceneFactory.chatScene(
            visibleNotificationSourceChatIds: ["notification-0"],
            mentionPickerVisible: false,
            composerFocused: true,
            notificationReplyFocusedSourceChatId: nil,
            actionMenuSourceChatId: nil
        )
        assertRoute(.transcriptBubbleScrollForward, in: store, isHandledBy: .transcript, rule: "PR-04")
        assertRoute(.transcriptBubbleScrollBackward, in: store, isHandledBy: .transcript, rule: "PR-04")
        assertRoute(.notificationScrollForward, in: store, isHandledBy: .notificationBubble("notification-0"), rule: "PR-04")
        assertRoute(.notificationScrollBackward, in: store, isHandledBy: .notificationBubble("notification-0"), rule: "PR-04")
        assertRoute(.transcriptChatScrollForward, in: store, isHandledBy: .transcript, rule: "PR-07")
        assertRoute(.transcriptChatScrollBackward, in: store, isHandledBy: .transcript, rule: "PR-07")
    }

    @Test("Visible notification scroll shortcuts stay on the central command bridge")
    func visibleNotificationScrollShortcutsStayOnCentralCommandBridge() {
        #expect(
            CrossChatNotificationGlobalShortcut.scrollSpecs(visibleNotificationCount: 2) == [
                .init(input: "j", modifiers: .command, action: .scrollDown),
                .init(input: "k", modifiers: .command, action: .scrollUp),
            ]
        )
        #expect(CrossChatNotificationGlobalShortcut.Action.scrollDown.rootScrollIntent == .transcriptBubbleScrollForward)
        #expect(CrossChatNotificationGlobalShortcut.Action.scrollUp.rootScrollIntent == .transcriptBubbleScrollBackward)
    }

    @Test("T1154 visible notification Cmd-J/K fallback posts root fan-out scroll commands")
    @MainActor
    func visibleNotificationCommandJFallbackPostsRootFanOutScrollCommands() {
        let store = KeyboardOwnershipSceneFactory.chatScene(
            visibleNotificationSourceChatIds: ["notification-0"],
            mentionPickerVisible: false,
            composerFocused: true,
            notificationReplyFocusedSourceChatId: nil,
            actionMenuSourceChatId: nil
        )

        #expect(
            CrossChatNotificationGlobalShortcut.notificationNames(
                for: .scrollDown,
                keyboardOwnershipStore: store
            ) == [
                .clawlineScrollNotificationDownCommand,
                .clawlineScrollDownCommand
            ]
        )
        #expect(
            CrossChatNotificationGlobalShortcut.notificationNames(
                for: .scrollUp,
                keyboardOwnershipStore: store
            ) == [
                .clawlineScrollNotificationUpCommand,
                .clawlineScrollUpCommand
            ]
        )
    }

    @Test("Notification scroll resolver finds ancestor scroll view")
    @MainActor
    func notificationScrollResolverFindsAncestorScrollView() {
        let scrollView = UIScrollView()
        let content = UIView()
        let resolver = UIView()

        scrollView.addSubview(content)
        content.addSubview(resolver)

        #expect(NotificationScrollViewLookup.resolve(from: resolver) === scrollView)
    }

    @Test("Notification scroll resolver does not bind sibling scroll view")
    @MainActor
    func notificationScrollResolverDoesNotBindSiblingScrollView() {
        let localHost = UIView()
        let scrollView = UIScrollView()
        let scrollContent = UIView()
        let resolverContainer = UIView()
        let resolver = UIView()

        localHost.addSubview(scrollView)
        scrollView.addSubview(scrollContent)
        localHost.addSubview(resolverContainer)
        resolverContainer.addSubview(resolver)

        #expect(NotificationScrollViewLookup.resolve(from: resolver) == nil)
    }

    @Test("T1154 notification scroll resolver retries transient lifecycle misses")
    func notificationScrollResolverRetriesTransientLifecycleMisses() {
        #expect(NotificationScrollViewResolverRetryPolicy.shouldRetry(afterAttempt: 0))
        #expect(NotificationScrollViewResolverRetryPolicy.shouldRetry(afterAttempt: 2))
        #expect(NotificationScrollViewResolverRetryPolicy.shouldRetry(afterAttempt: 3) == false)
    }

    @Test("T1154 notification shortcut host identity tracks reply chat and stream popup lifecycle")
    func notificationShortcutHostIdentityTracksReplyChatAndStreamPopupLifecycle() {
        let beforeReply = KeyboardOwnershipSceneFactory.chatScene(
            visibleNotificationSourceChatIds: ["notification-0"],
            mentionPickerVisible: false,
            composerFocused: true,
            notificationReplyFocusedSourceChatId: nil,
            actionMenuSourceChatId: nil
        )
        let inReply = KeyboardOwnershipSceneFactory.chatScene(
            visibleNotificationSourceChatIds: ["notification-0"],
            mentionPickerVisible: false,
            composerFocused: false,
            notificationReplySourceChatIds: ["notification-0"],
            notificationReplyFocusedSourceChatId: "notification-0",
            actionMenuSourceChatId: nil
        )

        let beforeIdentity = CrossChatNotificationShortcutLifecycle.identity(
            sourceStates: [(sourceChatId: "notification-0", isReplying: false)],
            keyboardOwnershipStore: beforeReply,
            selectedSessionKey: "chat-a",
            streamPopupRoute: .closed
        )
        let replyIdentity = CrossChatNotificationShortcutLifecycle.identity(
            sourceStates: [(sourceChatId: "notification-0", isReplying: true)],
            keyboardOwnershipStore: inReply,
            selectedSessionKey: "chat-a",
            streamPopupRoute: .closed
        )
        let switchedChatIdentity = CrossChatNotificationShortcutLifecycle.identity(
            sourceStates: [(sourceChatId: "notification-0", isReplying: false)],
            keyboardOwnershipStore: beforeReply,
            selectedSessionKey: "chat-b",
            streamPopupRoute: .closed
        )
        let popupOpenIdentity = CrossChatNotificationShortcutLifecycle.identity(
            sourceStates: [(sourceChatId: "notification-0", isReplying: false)],
            keyboardOwnershipStore: beforeReply,
            selectedSessionKey: "chat-a",
            streamPopupRoute: .popup(searchFocus: .request(id: 1))
        )
        let popupFilteringIdentity = CrossChatNotificationShortcutLifecycle.identity(
            sourceStates: [(sourceChatId: "notification-0", isReplying: false)],
            keyboardOwnershipStore: beforeReply,
            selectedSessionKey: "chat-a",
            streamPopupRoute: .popup(searchFocus: .none)
        )
        let recoveredIdentity = CrossChatNotificationShortcutLifecycle.identity(
            sourceStates: [(sourceChatId: "notification-0", isReplying: false)],
            keyboardOwnershipStore: beforeReply,
            selectedSessionKey: "chat-a",
            streamPopupRoute: .closed
        )

        #expect(beforeIdentity != replyIdentity)
        #expect(beforeIdentity != switchedChatIdentity)
        #expect(beforeIdentity != popupOpenIdentity)
        #expect(beforeIdentity != popupFilteringIdentity)
        #expect(beforeIdentity == recoveredIdentity)
    }

    @Test("T1154 notification scroll command moves registered overflow content")
    @MainActor
    func notificationScrollCommandMovesRegisteredOverflowContent() {
        let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 120, height: 320))
        scrollView.contentSize = CGSize(width: 120, height: 720)
        scrollView.contentOffset = .zero
        let pageIncrement = max(80, scrollView.bounds.height * 0.82)

        #expect(CrossChatNotificationScrollCommand.lineIncrement == 224)
        #expect(CrossChatNotificationScrollCommand.lineIncrement < pageIncrement)
        #expect(CrossChatNotificationScrollCommand.scroll(scrollView, direction: .down))
        #expect(scrollView.contentOffset.y == CrossChatNotificationScrollCommand.lineIncrement)

        #expect(CrossChatNotificationScrollCommand.scroll(scrollView, direction: .up))
        #expect(scrollView.contentOffset.y == 0)
    }

    @Test("T1154 notification scroll command caps doubled movement below page jumps")
    @MainActor
    func notificationScrollCommandCapsDoubledMovementBelowPageJumps() {
        let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 120, height: 160))
        scrollView.contentSize = CGSize(width: 120, height: 420)
        scrollView.contentOffset = .zero
        let pageIncrement = max(80, scrollView.bounds.height * 0.82)
        let expectedIncrement = pageIncrement - 1

        #expect(CrossChatNotificationScrollCommand.scroll(scrollView, direction: .down))
        #expect(abs(scrollView.contentOffset.y - expectedIncrement) < 0.5)
        #expect(scrollView.contentOffset.y < pageIncrement)
    }

    @Test("T1154 notification scroll command clamps near content edges")
    @MainActor
    func notificationScrollCommandClampsNearContentEdges() {
        let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 120, height: 320))
        scrollView.contentSize = CGSize(width: 120, height: 600)
        scrollView.contentOffset = CGPoint(x: 0, y: 240)
        let maxY = scrollView.contentSize.height - scrollView.bounds.height

        #expect(CrossChatNotificationScrollCommand.scroll(scrollView, direction: .down))
        #expect(scrollView.contentOffset.y == maxY)

        #expect(CrossChatNotificationScrollCommand.scroll(scrollView, direction: .down) == false)
        #expect(scrollView.contentOffset.y == maxY)
    }

    @Test("T1154 notification scroll command no-ops without overflow")
    @MainActor
    func notificationScrollCommandNoopsWithoutOverflow() {
        let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 120, height: 100))
        scrollView.contentSize = CGSize(width: 120, height: 100)

        #expect(CrossChatNotificationScrollCommand.scroll(scrollView, direction: .down) == false)
        #expect(scrollView.contentOffset.y == 0)
        #expect(CrossChatNotificationScrollCommand.scroll(nil, direction: .down) == false)
    }

    @Test("T1154 notification scroll target chooses top visible over last focused bubble")
    func notificationScrollTargetChoosesTopVisibleOverLastFocusedBubble() {
        #expect(
            CrossChatNotificationScrollTargetSelection.sourceChatId(
                visibleSourceChatIds: ["notification-0", "notification-1", "notification-2"],
                routedSourceChatId: "notification-2"
            ) == "notification-0"
        )
    }

    @Test("T1154 notification scroll target requires notification routing ownership")
    func notificationScrollTargetRequiresNotificationRoutingOwnership() {
        #expect(
            CrossChatNotificationScrollTargetSelection.sourceChatId(
                visibleSourceChatIds: ["notification-0", "notification-1"],
                routedSourceChatId: nil
            ) == nil
        )
        #expect(
            CrossChatNotificationScrollTargetSelection.sourceChatId(
                visibleSourceChatIds: [],
                routedSourceChatId: "notification-1"
            ) == nil
        )
    }

    @Test("T351 notification overlay host reports viewport width, not motion overflow width")
    func notificationOverlayHostReportsViewportWidthNotMotionOverflowWidth() {
        #expect(CrossChatNotificationGeometry.layoutHostWidth(maxContainerWidth: 393) == 393)
        #expect(CrossChatNotificationGeometry.layoutHostWidth(maxContainerWidth: 0) == 0)
        #expect(CrossChatNotificationGeometry.layoutHostWidth(maxContainerWidth: -10) == 0)
    }

    @Test("T1183 compact notification height keeps current cap")
    func compactNotificationHeightKeepsCurrentCap() {
        #expect(CrossChatNotificationGeometry.bubbleMaxHeight(isCompactLayout: true) == 164)
    }

    @Test("T1183 non-compact notification height allows double cap")
    func nonCompactNotificationHeightAllowsDoubleCap() {
        #expect(
            CrossChatNotificationGeometry.bubbleMaxHeight(isCompactLayout: false)
                == CrossChatNotificationGeometry.bubbleMaxHeight(isCompactLayout: true) * 2
        )
    }

    @Test("T1183 non-compact notification height still shrinks below cap")
    func nonCompactNotificationHeightStillShrinksBelowCap() {
        let nonCompactContentCap = CrossChatNotificationGeometry.bubbleMaxHeight(isCompactLayout: false) - 94
        #expect(
            CrossChatNotificationEntrySurfaceGeometry.entriesNeedScroll(
                measuredContentHeight: 80,
                contentMaxHeight: nonCompactContentCap
            ) == false
        )
    }

    @Test("T373 Spatial notification material uses adaptive tint and stronger accent")
    func spatialNotificationMaterialUsesAdaptiveTintAndAccent() {
        #expect(CrossChatNotificationMaterialStyle.backgroundOpacity == 0.95)
        #expect(CrossChatNotificationMaterialStyle.accentOpacity(isSpatial: true) == 0.60)
        #expect(CrossChatNotificationMaterialStyle.accentOpacity(isSpatial: false) == 0.40)
        #expect(CrossChatNotificationMaterialStyle.spatialTintOpacity(for: .light) >= 0.68)
        #expect(CrossChatNotificationMaterialStyle.spatialTintOpacity(for: .dark) >= 0.52)
        #expect(CrossChatNotificationMaterialStyle.spatialTintOpacity(for: .light) > CrossChatNotificationMaterialStyle.spatialTintOpacity(for: .dark))
        #expect(CrossChatNotificationMaterialStyle.spatialBorderOpacity(for: .light) > CrossChatNotificationMaterialStyle.spatialBorderOpacity(for: .dark))
    }

    @Test("Notification reply field keeps notification numbers and Cmd-J/K fan-out above text focus")
    @MainActor
    func notificationReplyFieldKeepsNotificationNumbersAndFanOutAboveTextFocus() {
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

        let textView = NotificationReplyUITextView()
        textView.visibleNotificationCount = 4
        textView.keyboardOwnershipStore = store
        let firstCommandJ = textView.keyCommands?.first { command in
            command.input == "j" && command.modifierFlags == [.command]
        }
        let firstCommandShiftJ = textView.keyCommands?.first { command in
            command.input == "j" && command.modifierFlags == [.command, .shift]
        }

        #expect(firstCommandJ?.action == #selector(UIResponder.clawlineScrollDownCommand(_:)))
        #expect(firstCommandShiftJ?.action == #selector(UIResponder.clawlineScrollChatDownCommand(_:)))
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
        assertRoute(.transcriptBubbleScrollForward, in: composerFocusedStore, isHandledBy: .transcript, rule: "PR-07")
        assertRoute(.transcriptChatScrollForward, in: composerFocusedStore, isHandledBy: .transcript, rule: "PR-07")
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
                currentFirstResponderOwnsTerminalInput: false,
                currentFirstResponderOwnsEmbeddedScroll: false,
                canRetryAfterTextInput: true
            ) == .activate
        )
        #expect(
            PromptFocusShortcutActivation.action(
                isShortcutEnabled: true,
                isAlreadyFirstResponder: false,
                currentFirstResponderIsTextInput: true,
                currentFirstResponderOwnsTerminalInput: false,
                currentFirstResponderOwnsEmbeddedScroll: false,
                canRetryAfterTextInput: false
            ) == .skip
        )
        #expect(
            PromptFocusShortcutActivation.action(
                isShortcutEnabled: false,
                isAlreadyFirstResponder: false,
                currentFirstResponderIsTextInput: false,
                currentFirstResponderOwnsTerminalInput: false,
                currentFirstResponderOwnsEmbeddedScroll: false,
                canRetryAfterTextInput: true
            ) == .skip
        )
        #expect(
            PromptFocusShortcutActivation.action(
                isShortcutEnabled: true,
                isAlreadyFirstResponder: true,
                currentFirstResponderIsTextInput: false,
                currentFirstResponderOwnsTerminalInput: false,
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
                currentFirstResponderOwnsTerminalInput: false,
                currentFirstResponderOwnsEmbeddedScroll: true,
                canRetryAfterTextInput: true
            ) == .skip
        )
    }

    @Test("Prompt focus shortcut does not steal focus from terminal input")
    func promptFocusShortcutDoesNotStealFocusFromTerminalInput() {
        #expect(
            PromptFocusShortcutActivation.action(
                isShortcutEnabled: true,
                isAlreadyFirstResponder: false,
                currentFirstResponderIsTextInput: false,
                currentFirstResponderOwnsTerminalInput: true,
                currentFirstResponderOwnsEmbeddedScroll: false,
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
                currentFirstResponderOwnsTerminalInput: false,
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

private func assertModifiedReturnCommands(in commands: [UIKeyCommand]?, action: Selector) {
    let commandInputs = ["\r", "\n"]
    let modifierFlags: [UIKeyModifierFlags] = [.control, .shift]

    for input in commandInputs {
        for flags in modifierFlags {
            #expect(
                commands?.contains { command in
                    command.input == input
                        && command.modifierFlags == flags
                        && command.action == action
                } == true
            )
        }
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
}

private final class ScrollCommandNotificationRecorder: NSObject {
    var postedNames: [Notification.Name] = []

    @objc func record(_ notification: Notification) {
        postedNames.append(notification.name)
    }
}
