//
//  RichTextEditor.swift
//  Clawline
//
//  Created by Codex on 1/15/26.
//

import OSLog
import SwiftUI
import UIKit
import UniformTypeIdentifiers

private let logger = Logger(subsystem: "co.clicketyclacks.Clawline", category: "RichTextEditor")

enum PromptEditorSelectionPolicy: Equatable {
    case preserve
    case moveToInsertedEnd
    case selectReplacement
    case restoreSnapshotSelection
    case documentEnd
}

enum PromptEditorIntent {
    case focus(reason: String)
    case blur(reason: String)
    case replaceDraft(content: NSAttributedString, selectionPolicy: PromptEditorSelectionPolicy, reason: String)
    case insertText(text: String, selectionPolicy: PromptEditorSelectionPolicy, reason: String)
    case insertAttachment(payload: PendingAttachment, selectionPolicy: PromptEditorSelectionPolicy)
    case insertResolvedMention(mention: String, selectionPolicy: PromptEditorSelectionPolicy)
    case requestSnapshot(reason: String)
    case setEditable(Bool)
    case performEditorCommand(PromptEditorCommand)
}

enum PromptEditorEvent {
    case draftChanged(revision: Int, content: NSAttributedString, editKind: PromptEditorEditKind)
    case focusChanged(isFocused: Bool)
    case heightChanged(value: CGFloat)
    case submitRequested
    case modifiedNewlineRequested
    case cancelRequested
    case pasteImagesRequested(images: [UIImage])
    case compositionChanged(isActive: Bool)
    case snapshotReady(snapshot: PromptEditorSnapshot, reason: String)
}

enum PromptEditorCommand: Equatable {
    case submit
    case modifiedNewline
    case cancel
    case mentionPickerAccept
    case mentionPickerMoveUp
    case mentionPickerMoveDown
}

enum PromptEditorEditKind: Equatable {
    case user
    case programmatic
}

struct PromptEditorSnapshot: Equatable {
    var revision: Int
    var contentLength: Int
    var selectedRange: NSRange
    var isComposing: Bool
    var isFocused: Bool
}

struct PromptEditorMutationSource: Equatable {
    enum Origin: Equatable {
        case parent
        case editor
    }

    var revision: Int
    var origin: Origin
    var reason: String
}

final class PromptEditorController {
    private(set) var revision: Int = 0
    private var lastParentMutation: PromptEditorMutationSource?

    func recordParentMutation(reason: String) -> PromptEditorMutationSource {
        revision += 1
        let source = PromptEditorMutationSource(revision: revision, origin: .parent, reason: reason)
        lastParentMutation = source
        return source
    }

    func recordEditorDraftChange(content: NSAttributedString, editKind: PromptEditorEditKind) -> PromptEditorEvent {
        revision += 1
        return .draftChanged(revision: revision, content: content, editKind: editKind)
    }

    func snapshot(contentLength: Int, selectedRange: NSRange, isComposing: Bool, isFocused: Bool) -> PromptEditorSnapshot {
        PromptEditorSnapshot(
            revision: revision,
            contentLength: contentLength,
            selectedRange: selectedRange,
            isComposing: isComposing,
            isFocused: isFocused
        )
    }

    func shouldSuppressEcho(from source: PromptEditorMutationSource) -> Bool {
        source.origin == .parent && source == lastParentMutation && source.revision == revision
    }

    func selectionRange(
        policy: PromptEditorSelectionPolicy,
        replacementRange: NSRange,
        replacementLength: Int,
        documentLengthAfterReplacement: Int,
        currentSelection: NSRange,
        snapshot: PromptEditorSnapshot? = nil
    ) -> NSRange {
        Self.selectionRange(
            policy: policy,
            replacementRange: replacementRange,
            replacementLength: replacementLength,
            documentLengthAfterReplacement: documentLengthAfterReplacement,
            currentSelection: currentSelection,
            snapshot: snapshot,
            currentRevision: revision
        )
    }

    static func selectionRange(
        policy: PromptEditorSelectionPolicy,
        replacementRange: NSRange,
        replacementLength: Int,
        documentLengthAfterReplacement: Int,
        currentSelection: NSRange,
        snapshot: PromptEditorSnapshot? = nil,
        currentRevision: Int
    ) -> NSRange {
        let clampedReplacement = clamp(replacementRange, length: documentLengthAfterReplacement)
        switch policy {
        case .preserve:
            return clamp(currentSelection, length: documentLengthAfterReplacement)
        case .moveToInsertedEnd:
            let location = min(clampedReplacement.location + max(0, replacementLength), documentLengthAfterReplacement)
            return NSRange(location: location, length: 0)
        case .selectReplacement:
            let length = min(max(0, replacementLength), max(0, documentLengthAfterReplacement - clampedReplacement.location))
            return NSRange(location: clampedReplacement.location, length: length)
        case .restoreSnapshotSelection:
            guard let snapshot, snapshot.revision == currentRevision else {
                return clamp(currentSelection, length: documentLengthAfterReplacement)
            }
            return clamp(snapshot.selectedRange, length: documentLengthAfterReplacement)
        case .documentEnd:
            return NSRange(location: documentLengthAfterReplacement, length: 0)
        }
    }

    private static func clamp(_ range: NSRange, length: Int) -> NSRange {
        guard range.location != NSNotFound else {
            return NSRange(location: length, length: 0)
        }
        let safeLocation = min(max(range.location, 0), length)
        let safeLength = max(0, min(range.length, length - safeLocation))
        return NSRange(location: safeLocation, length: safeLength)
    }
}

enum PromptEditorTelemetryEvent: String {
    case bridgeUpdateUIView = "bridge.updateUIView"
    case editorTextDidChange = "editor.textDidChange"
    case editorSelectionDidChange = "editor.selectionDidChange"
    case editorHeightMeasured = "editor.heightMeasured"
    case editorHeightMeasurementSkipped = "editor.heightMeasurementSkipped"
    case editorHeightEmitted = "editor.heightEmitted"
    case focusIntent = "focus.intent"
    case focusAck = "focus.ack"
    case commandCapture = "command.capture"
    case commandRoute = "command.route"
    case compositionActive = "composition.active"
    case legacyBindingWrite = "legacy.bindingWrite"
}

enum PromptEditorBridgeTelemetry {
    static let launchArgument = "--debug-prompt-editor-bridge"

    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains(launchArgument)
    }

    static func record(_ event: PromptEditorTelemetryEvent, _ fields: [String: CustomStringConvertible] = [:]) {
        guard isEnabled else { return }
        let details = fields
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        logger.debug("[prompt-editor-bridge] \(event.rawValue, privacy: .public) \(details, privacy: .public)")
    }
}

private extension UIKey {
    var hasNoCommandModifiers: Bool {
        modifierFlags.intersection([.command, .shift, .alternate, .control]).isEmpty
    }
}

struct RichTextEditor: UIViewRepresentable {
    @Binding var attributedText: NSAttributedString
    @Binding var calculatedHeight: CGFloat
    @Binding var selectionRange: NSRange
    @Binding var pendingInsertions: [PendingAttachment]
    var fontScaleChangeSequence: Int
    var resetToken: Int
    var focusTrigger: Int
    var dismissTrigger: Int
    var isEditable: Bool
    var isKeyboardVisible: Bool
    var isExternalEditingActive: Bool = false
    var tintColor: UIColor
    var textColor: UIColor = .label
    var onFocusChange: (Bool) -> Void
    var onTextEditActivity: (() -> Void)?
    var onSubmit: (() -> Void)?
    var onEscape: (() -> Void)?
    var onEscapeLongPress: (() -> Void)?
    var handlesMentionPickerKeyCommands: Bool = false
    var mentionPickerHasCompletion: Bool = false
    var onMentionPickerTab: (() -> Void)?
    var onMentionPickerMoveUp: (() -> Void)?
    var onMentionPickerMoveDown: (() -> Void)?
    var onPasteImages: (([UIImage]) -> Void)?
    var onUserEdit: ((NSRange, Int) -> Void)?
    var onTextViewReady: ((PastableTextView) -> Void)?
    var notificationVisibleCount: Int = 0
    var keyboardOwnershipStore = KeyboardOwnershipStore()
    var trailingPadding: CGFloat = 20

    func makeUIView(context: Context) -> PastableTextView {
        let textView = PastableTextView()
        textView.delegate = context.coordinator
        let coordinator = context.coordinator
        textView.onPasteImages = { images in
            PromptEditorBridgeTelemetry.record(.commandCapture, [
                "route": "pasteImages",
                "count": images.count
            ])
            coordinator.parent.onPasteImages?(images)
        }
        textView.onEscape = {
            coordinator.parent.onEscape?()
        }
        textView.onEscapeLongPress = {
            coordinator.parent.onEscapeLongPress?()
        }
        textView.onLayout = { _ in
            coordinator.updateHeight(for: textView, allowAutoScroll: false)
        }
        textView.onResponderFocusChange = { isFocused in
            PromptEditorBridgeTelemetry.record(.focusAck, ["isFocused": isFocused, "reason": "responder"])
            coordinator.parent.onFocusChange(isFocused)
        }
        textView.onDirectUserTextReplacement = { range, replacementText in
            coordinator.parent.onUserEdit?(range, replacementText.utf16.count)
        }
        textView.handlesMentionPickerKeyCommands = handlesMentionPickerKeyCommands
        textView.notificationVisibleCount = notificationVisibleCount
        textView.keyboardOwnershipStore = keyboardOwnershipStore
        textView.onMentionPickerTab = { coordinator.parent.onMentionPickerTab?() }
        textView.onMentionPickerMoveUp = { coordinator.parent.onMentionPickerMoveUp?() }
        textView.onMentionPickerMoveDown = { coordinator.parent.onMentionPickerMoveDown?() }
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 20, bottom: 12, right: trailingPadding)
        textView.textContainer.lineFragmentPadding = 0
        textView.adjustsFontForContentSizeCategory = true
        textView.font = UIFont.clawline(.bodyText)
        textView.allowsEditingTextAttributes = true
#if !os(visionOS)
        textView.keyboardDismissMode = .none
#endif
        textView.returnKeyType = .send
        textView.accessibilityIdentifier = "compose-text-view"
        textView.accessibilityLabel = "Compose message"
        textView.tintColor = tintColor
        textView.textColor = textColor
        textView.autocorrectionType = .yes
        textView.smartQuotesType = .yes
        textView.smartDashesType = .yes
        textView.smartInsertDeleteType = .yes
        textView.attributedText = attributedText
        textView.isInputEnabled = isEditable
        let focusTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleEditorTap(_:)))
        focusTap.cancelsTouchesInView = false
        focusTap.delegate = context.coordinator
        textView.addGestureRecognizer(focusTap)
        textView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        onTextViewReady?(textView)
        return textView
    }

    func updateUIView(_ textView: PastableTextView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.isUpdatingFromSwiftUI = true
        defer { context.coordinator.isUpdatingFromSwiftUI = false }
        PromptEditorBridgeTelemetry.record(.bridgeUpdateUIView, [
            "contentLength": attributedText.length,
            "dismissTrigger": dismissTrigger,
            "focusTrigger": focusTrigger,
            "isEditable": isEditable,
            "pendingInsertions": pendingInsertions.count,
            "resetToken": resetToken,
            "selectionLocation": selectionRange.location,
            "selectionLength": selectionRange.length
        ])

        // Update paste callback
        let coordinator = context.coordinator
        textView.onPasteImages = { images in
            PromptEditorBridgeTelemetry.record(.commandCapture, [
                "route": "pasteImages",
                "count": images.count
            ])
            coordinator.parent.onPasteImages?(images)
        }
        textView.onEscape = {
            coordinator.parent.onEscape?()
        }
        textView.onEscapeLongPress = {
            coordinator.parent.onEscapeLongPress?()
        }
        textView.onLayout = { _ in
            coordinator.updateHeight(for: textView, allowAutoScroll: false)
        }
        onTextViewReady?(textView)
        textView.onResponderFocusChange = { isFocused in
            PromptEditorBridgeTelemetry.record(.focusAck, ["isFocused": isFocused, "reason": "responder"])
            coordinator.parent.onFocusChange(isFocused)
        }
        textView.onDirectUserTextReplacement = { range, replacementText in
            coordinator.parent.onUserEdit?(range, replacementText.utf16.count)
        }
        textView.handlesMentionPickerKeyCommands = handlesMentionPickerKeyCommands
        textView.notificationVisibleCount = notificationVisibleCount
        textView.keyboardOwnershipStore = keyboardOwnershipStore
        textView.onMentionPickerTab = { coordinator.parent.onMentionPickerTab?() }
        textView.onMentionPickerMoveUp = { coordinator.parent.onMentionPickerMoveUp?() }
        textView.onMentionPickerMoveDown = { coordinator.parent.onMentionPickerMoveDown?() }

        let isComposing = textView.markedTextRange != nil
        if isComposing {
            PromptEditorBridgeTelemetry.record(.compositionActive, ["isActive": true])
        }
        let resetRequested = resetToken != context.coordinator.lastResetToken
        let parentContentChangedWhileInactive = !textView.isFirstResponder
            && !textView.attributedText.isEqual(to: attributedText)
        if (resetRequested || parentContentChangedWhileInactive), !isComposing {
            context.coordinator.lastResetToken = resetToken
            _ = context.coordinator.controller.recordParentMutation(
                reason: resetRequested ? "resetToken" : "inactiveParentContent"
            )
            context.coordinator.invalidateHeightMeasurementFastPath()
            textView.attributedText = attributedText
            context.coordinator.enforceBaseAttributes(on: textView)
            if selectionRange.location != NSNotFound, textView.selectedRange != selectionRange {
                context.coordinator.isApplyingParentSelection = true
                textView.selectedRange = selectionRange
                context.coordinator.isApplyingParentSelection = false
            }
        }
        context.coordinator.isApplyingLocalEdit = false

        if !isComposing,
           !((textView.attributedText?.isEqual(attributedText)) ?? false) {
            _ = context.coordinator.controller.recordParentMutation(reason: "externalBinding")
            context.coordinator.invalidateHeightMeasurementFastPath()
            textView.attributedText = attributedText
            context.coordinator.enforceBaseAttributes(on: textView)
            context.coordinator.ensureTypingAttributes(on: textView)
        }

        if textView.isInputEnabled != isEditable {
            textView.isInputEnabled = isEditable
        }

#if !os(visionOS)
        if textView.keyboardDismissMode != .none {
            textView.keyboardDismissMode = .none
        }
#endif

        if textView.tintColor != tintColor {
            textView.tintColor = tintColor
        }
        if textView.textColor != textColor {
            textView.textColor = textColor
        }
        let baseFont = UIFont.clawline(.bodyText)
        if textView.font?.pointSize != baseFont.pointSize {
            textView.font = baseFont
        }

        let currentInset = textView.textContainerInset
        if abs(currentInset.right - trailingPadding) > 0.5 {
            textView.textContainerInset = UIEdgeInsets(top: currentInset.top,
                                                       left: currentInset.left,
                                                       bottom: currentInset.bottom,
                                                       right: trailingPadding)
        }

        context.coordinator.applyFocusIfNeeded(
            on: textView,
            trigger: focusTrigger,
            isKeyboardVisible: isKeyboardVisible
        )
        context.coordinator.applyDismissIfNeeded(
            on: textView,
            trigger: dismissTrigger
        )
        context.coordinator.updateHeightFromSwiftUIIfNeeded(for: textView)
        context.coordinator.enforceBaseAttributesIfNeeded(
            on: textView,
            fontScaleChangeSequence: fontScaleChangeSequence
        )
        context.coordinator.ensureTypingAttributes(on: textView)

        if !pendingInsertions.isEmpty, !isComposing, !context.coordinator.isInsertingAttachments {
            context.coordinator.isInsertingAttachments = true
            let attachments = pendingInsertions
            context.coordinator.insertAttachments(attachments, into: textView)
            DispatchQueue.main.async {
                PromptEditorBridgeTelemetry.record(.legacyBindingWrite, [
                    "binding": "pendingInsertions",
                    "count": 0
                ])
                self.pendingInsertions = []
                context.coordinator.isInsertingAttachments = false
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
        var parent: RichTextEditor
        let controller: PromptEditorController
        private var lastFocusTrigger: Int = 0
        private var lastDismissTrigger: Int = 0
        var isApplyingLocalEdit = false
        var isInsertingAttachments = false
        var isUpdatingFromSwiftUI = false
        var isApplyingParentSelection = false
        var lastResetToken: Int = 0
        private var lastBaseTextColor: UIColor?
        private var lastBaseFontPointSize: CGFloat?
        private var lastFontScaleChangeSequence: Int?
        private var heightRetryPending = false
        private var lastHeightMeasurement: HeightMeasurement?
        private var lastSkippedHeightTextLength: Int?
        private var pendingCaretVisibilityRequest: CaretVisibilityRequest?

        private struct HeightMeasurement {
            var width: CGFloat
            var textLength: Int
            var isScrollEnabled: Bool
        }

        private struct CaretVisibilityRequest: Equatable {
            var selectedRange: NSRange
            var textLength: Int
            var width: CGFloat
        }

        init(parent: RichTextEditor) {
            self.parent = parent
            self.controller = PromptEditorController()
        }

        @objc func handleEditorTap(_ gesture: UITapGestureRecognizer) {
            guard let textView = gesture.view as? UITextView else { return }
            requestEditorFocus(on: textView, isKeyboardVisible: parent.isKeyboardVisible, reason: "tap")
        }

        private func requestEditorFocus(on textView: UITextView, isKeyboardVisible: Bool, reason: String) {
            guard parent.isEditable else { return }
            PromptEditorBridgeTelemetry.record(.focusIntent, [
                "isFirstResponder": textView.isFirstResponder,
                "isKeyboardVisible": isKeyboardVisible,
                "reason": reason
            ])
            if let textView = textView as? PastableTextView {
                textView.isInputEnabled = true
            }
            textView.isEditable = true
            textView.isSelectable = true
            if Self.shouldCycleFirstResponder(
                isFirstResponder: textView.isFirstResponder,
                isKeyboardVisible: isKeyboardVisible
            ) {
                textView.resignFirstResponder()
                DispatchQueue.main.async { [weak self, weak textView] in
                    guard let self, let textView else { return }
                    let becameFirstResponder = textView.becomeFirstResponder()
                    if becameFirstResponder || textView.isFirstResponder {
                        PromptEditorBridgeTelemetry.record(.focusAck, ["isFocused": true, "reason": reason])
                        self.parent.onFocusChange(true)
                    }
                }
            } else if !textView.isFirstResponder {
                let becameFirstResponder = textView.becomeFirstResponder()
                if becameFirstResponder || textView.isFirstResponder {
                    PromptEditorBridgeTelemetry.record(.focusAck, ["isFocused": true, "reason": reason])
                    parent.onFocusChange(true)
                }
            } else {
                PromptEditorBridgeTelemetry.record(.focusAck, ["isFocused": true, "reason": reason])
                parent.onFocusChange(true)
            }
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            true
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            PromptEditorBridgeTelemetry.record(.focusAck, ["isFocused": true, "reason": "delegate"])
            parent.onFocusChange(true)
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            PromptEditorBridgeTelemetry.record(.focusAck, ["isFocused": false, "reason": "delegate"])
            parent.onFocusChange(false)
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !isUpdatingFromSwiftUI else { return }
            let isProgrammaticEdit = (textView as? PastableTextView)?.programmaticEditInFlight == true
            let draftEvent = controller.recordEditorDraftChange(
                content: textView.attributedText,
                editKind: isProgrammaticEdit ? .programmatic : .user
            )
            if case let .draftChanged(revision, content, editKind) = draftEvent {
                PromptEditorBridgeTelemetry.record(.editorTextDidChange, [
                    "contentLength": content.length,
                    "editKind": String(describing: editKind),
                    "revision": revision
                ])
            }
            isApplyingLocalEdit = true
            if !isProgrammaticEdit {
                parent.onTextEditActivity?()
            }
            if !parent.attributedText.isEqual(to: textView.attributedText) {
                PromptEditorBridgeTelemetry.record(.legacyBindingWrite, [
                    "binding": "attributedText",
                    "length": textView.attributedText.length
                ])
                parent.attributedText = textView.attributedText
            }
            if !isProgrammaticEdit {
                setSelectionRange(textView.selectedRange)
            }
            updateHeight(for: textView, allowAutoScroll: true)
            if !isProgrammaticEdit {
                ensureCaretVisible(in: textView)
            }
            ensureTypingAttributes(on: textView)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            if let textView = textView as? PastableTextView {
                if textView.consumeExpectedProgrammaticSelectionFeedback(textView.selectedRange) {
                    return
                }
                if textView.programmaticEditInFlight {
                    return
                }
            }
            let selectedRange = textView.selectedRange
            guard selectedRange.location != NSNotFound else { return }
            guard !isApplyingParentSelection else { return }
            PromptEditorBridgeTelemetry.record(.editorSelectionDidChange, [
                "location": selectedRange.location,
                "length": selectedRange.length
            ])
            parent.onTextEditActivity?()
            setSelectionRange(selectedRange)
            if isApplyingLocalEdit {
                ensureCaretVisible(in: textView)
            }
            ensureTypingAttributes(on: textView)
        }

        func textView(_ textView: UITextView,
                      shouldChangeTextIn range: NSRange,
                      replacementText text: String) -> Bool {
            if let textView = textView as? PastableTextView {
                guard !textView.programmaticEditInFlight else { return true }
                textView.clearExpectedProgrammaticSelectionFeedback()
                parent.onUserEdit?(range, text.utf16.count)
            } else {
                parent.onUserEdit?(range, text.utf16.count)
            }
            if text == "\n" {
                PromptEditorBridgeTelemetry.record(.commandCapture, ["route": "textSubmit"])
                let route = KeyboardCommandRouter.route(intent: .textSubmit, store: parent.keyboardOwnershipStore).outcome
                PromptEditorBridgeTelemetry.record(.commandRoute, [
                    "intent": "textSubmit",
                    "outcome": String(describing: route)
                ])
                switch route {
                case .handled(.mentionPicker):
                    parent.onMentionPickerTab?()
                case .handled(.composer):
                    parent.onSubmit?()
                default:
                    return true
                }
                return false
            }
            return true
        }

        func updateHeightFromSwiftUIIfNeeded(for textView: UITextView) {
            let targetWidth = textView.bounds.width
            if targetWidth > 1,
               let lastHeightMeasurement,
               abs(lastHeightMeasurement.width - targetWidth) <= 0.5,
               lastHeightMeasurement.textLength == textView.textStorage.length {
                PromptEditorBridgeTelemetry.record(.editorHeightMeasurementSkipped, [
                    "length": textView.textStorage.length,
                    "reason": "swiftUIUnchangedTextAndWidth",
                    "width": targetWidth
                ])
                return
            }
            updateHeight(for: textView, allowAutoScroll: false)
        }

        func updateHeight(for textView: UITextView, allowAutoScroll: Bool) {
            let targetWidth = textView.bounds.width
            guard targetWidth > 1 else {
                guard !heightRetryPending else { return }
                heightRetryPending = true
                DispatchQueue.main.async { [weak self, weak textView] in
                    guard let self, let textView else { return }
                    self.updateHeight(for: textView, allowAutoScroll: allowAutoScroll)
                }
                return
            }
            heightRetryPending = false
            let referenceWidth = targetWidth
            let minHeight: CGFloat = 44
            let maxHeight: CGFloat = 120
            let textLength = textView.textStorage.length
            let selectedRange = textView.selectedRange
            let isEndInsertionGrowth = allowAutoScroll && textLength > (lastHeightMeasurement?.textLength ?? textLength)
            let isFollowUpForSkippedText = !allowAutoScroll && lastSkippedHeightTextLength == textLength
            if let lastHeightMeasurement,
               lastHeightMeasurement.isScrollEnabled,
               abs(lastHeightMeasurement.width - referenceWidth) <= 0.5,
               textView.markedTextRange == nil,
               selectedRange.length == 0,
               selectedRange.location == textLength,
               (isEndInsertionGrowth || isFollowUpForSkippedText) {
                let clamped = maxHeight
                PromptEditorBridgeTelemetry.record(.editorHeightMeasurementSkipped, [
                    "clamped": clamped,
                    "length": textLength,
                    "previousLength": lastHeightMeasurement.textLength,
                    "reason": "maxHeightGrowth",
                    "width": targetWidth
                ])
                if abs(parent.calculatedHeight - clamped) > 0.5 {
                    emitHeight(clamped)
                    pendingCaretVisibilityRequest = nil
                }
                if !textView.isScrollEnabled {
                    textView.isScrollEnabled = true
                    pendingCaretVisibilityRequest = nil
                }
                if allowAutoScroll {
                    ensureCaretVisible(in: textView)
                }
                self.lastHeightMeasurement = HeightMeasurement(
                    width: referenceWidth,
                    textLength: textLength,
                    isScrollEnabled: true
                )
                lastSkippedHeightTextLength = textLength
                return
            }
            let fittingSize = CGSize(width: referenceWidth,
                                     height: .greatestFiniteMagnitude)
            let size = textView.sizeThatFits(fittingSize)
            let lineHeight = textView.font?.lineHeight ?? 17
            let singleLineHeight = lineHeight + textView.textContainerInset.top + textView.textContainerInset.bottom
            let clamped: CGFloat
            if size.height <= singleLineHeight + lineHeight * 0.5 {
                clamped = minHeight
            } else {
                clamped = min(max(size.height, minHeight), maxHeight)
            }
            PromptEditorBridgeTelemetry.record(.editorHeightMeasured, [
                "clamped": clamped,
                "measured": size.height,
                "width": targetWidth
            ])
            if abs(parent.calculatedHeight - clamped) > 0.5 {
                PromptEditorBridgeTelemetry.record(.editorHeightEmitted, ["value": clamped])
                emitHeight(clamped)
                pendingCaretVisibilityRequest = nil
            }
            let shouldScroll = size.height > maxHeight
            if textView.isScrollEnabled != shouldScroll {
                textView.isScrollEnabled = shouldScroll
                pendingCaretVisibilityRequest = nil
            }
            lastHeightMeasurement = HeightMeasurement(
                width: referenceWidth,
                textLength: textLength,
                isScrollEnabled: textView.isScrollEnabled
            )
            lastSkippedHeightTextLength = nil
            if textView.isScrollEnabled {
                if allowAutoScroll {
                    ensureCaretVisible(in: textView)
                }
            }
        }

        private func emitHeight(_ clamped: CGFloat) {
            if isUpdatingFromSwiftUI {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    guard abs(self.parent.calculatedHeight - clamped) > 0.5 else { return }
                    PromptEditorBridgeTelemetry.record(.legacyBindingWrite, [
                        "binding": "calculatedHeight",
                        "value": clamped
                    ])
                    self.parent.calculatedHeight = clamped
                }
            } else {
                PromptEditorBridgeTelemetry.record(.legacyBindingWrite, [
                    "binding": "calculatedHeight",
                    "value": clamped
                ])
                parent.calculatedHeight = clamped
            }
        }

        func invalidateHeightMeasurementFastPath() {
            lastSkippedHeightTextLength = nil
            pendingCaretVisibilityRequest = nil
        }

        static func shouldCycleFirstResponder(
            isFirstResponder: Bool,
            isKeyboardVisible: Bool
        ) -> Bool {
            isFirstResponder && !isKeyboardVisible
        }

        func applyFocusIfNeeded(on textView: UITextView, trigger: Int, isKeyboardVisible: Bool) {
            guard trigger != lastFocusTrigger else { return }
            lastFocusTrigger = trigger
            guard trigger > 0 else { return }
            guard parent.isEditable else { return }
            requestEditorFocus(on: textView, isKeyboardVisible: isKeyboardVisible, reason: "trigger")
        }

        func applyDismissIfNeeded(on textView: UITextView, trigger: Int) {
            guard trigger != lastDismissTrigger else { return }
            lastDismissTrigger = trigger
            guard trigger > 0 else { return }
            guard textView.isFirstResponder || parent.isKeyboardVisible else { return }
            PromptEditorBridgeTelemetry.record(.focusIntent, [
                "isFirstResponder": textView.isFirstResponder,
                "isKeyboardVisible": parent.isKeyboardVisible,
                "reason": "dismissTrigger"
            ])
            textView.resignFirstResponder()
            textView.window?.endEditing(true)
            PromptEditorBridgeTelemetry.record(.focusAck, ["isFocused": false, "reason": "dismissTrigger"])
            parent.onFocusChange(false)
        }

        private func ensureCaretVisible(in textView: UITextView) {
            guard textView.isScrollEnabled else { return }
            let range = textView.selectedRange
            let request = CaretVisibilityRequest(
                selectedRange: range,
                textLength: textView.textStorage.length,
                width: textView.bounds.width
            )
            guard pendingCaretVisibilityRequest != request else { return }
            pendingCaretVisibilityRequest = request
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let textView else { return }
                textView.scrollRangeToVisible(range)
                if self?.pendingCaretVisibilityRequest == request {
                    self?.pendingCaretVisibilityRequest = nil
                }
            }
        }

        private func setSelectionRange(_ selectedRange: NSRange) {
            guard parent.selectionRange != selectedRange else { return }
            if isUpdatingFromSwiftUI {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    guard self.parent.selectionRange != selectedRange else { return }
                    PromptEditorBridgeTelemetry.record(.legacyBindingWrite, [
                        "binding": "selectionRange",
                        "location": selectedRange.location,
                        "length": selectedRange.length
                    ])
                    self.parent.selectionRange = selectedRange
                }
            } else {
                PromptEditorBridgeTelemetry.record(.legacyBindingWrite, [
                    "binding": "selectionRange",
                    "location": selectedRange.location,
                    "length": selectedRange.length
                ])
                parent.selectionRange = selectedRange
            }
        }

        func ensureTypingAttributes(on textView: UITextView) {
            var attributes = textView.typingAttributes
            let baseFont = UIFont.clawline(.bodyText)
            let existingFont = attributes[.font] as? UIFont
            let existingColor = attributes[.foregroundColor] as? UIColor
            if existingFont?.pointSize == baseFont.pointSize,
               existingFont?.fontName == baseFont.fontName,
               existingColor?.isEqual(parent.textColor) == true {
                return
            }
            attributes[.font] = baseFont
            attributes[.foregroundColor] = parent.textColor
            textView.typingAttributes = attributes
        }

        func enforceBaseAttributesIfNeeded(on textView: UITextView, fontScaleChangeSequence: Int) {
            let baseFont = UIFont.clawline(.bodyText)
            let colorUnchanged = lastBaseTextColor?.isEqual(parent.textColor) == true
            let fontUnchanged = lastBaseFontPointSize == baseFont.pointSize
            let sequenceUnchanged = lastFontScaleChangeSequence == fontScaleChangeSequence
            if colorUnchanged && fontUnchanged && sequenceUnchanged {
                return
            }
            lastBaseTextColor = parent.textColor
            lastBaseFontPointSize = baseFont.pointSize
            lastFontScaleChangeSequence = fontScaleChangeSequence
            enforceBaseAttributes(on: textView, baseFont: baseFont)
        }

        func enforceBaseAttributes(on textView: UITextView, baseFont: UIFont = UIFont.clawline(.bodyText)) {
            let baseColor = parent.textColor
            let fullRange = NSRange(location: 0, length: textView.textStorage.length)
            guard fullRange.length > 0 else { return }

            textView.textStorage.enumerateAttribute(.attachment, in: fullRange, options: []) { value, range, _ in
                guard value == nil else { return }
                textView.textStorage.addAttributes([.font: baseFont, .foregroundColor: baseColor], range: range)
            }
        }

        func insertAttachments(_ attachments: [PendingAttachment], into textView: UITextView) {
            guard !attachments.isEmpty else { return }
            if let textView = textView as? PastableTextView {
                textView.programmaticEditInFlight = true
            }
            defer {
                if let textView = textView as? PastableTextView {
                    textView.programmaticEditInFlight = false
                }
            }
            let mutable = NSMutableAttributedString(attributedString: textView.attributedText ?? NSAttributedString())
            let safeRange = clamp(textView.selectedRange, length: mutable.length)
            mutable.replaceCharacters(in: safeRange, with: NSAttributedString(string: ""))
            var insertionLocation = safeRange.location
            for attachment in attachments {
                let textAttachment = PendingTextAttachment(
                    id: attachment.id,
                    thumbnail: attachment.thumbnail,
                    accessibilityLabel: attachment.accessibilityLabel
                )
                let attachmentString = NSAttributedString(attachment: textAttachment)
                mutable.insert(attachmentString, at: insertionLocation)
                insertionLocation += attachmentString.length
            }
            textView.attributedText = mutable
            let newRange = NSRange(location: insertionLocation, length: 0)
            if let textView = textView as? PastableTextView {
                textView.expectProgrammaticSelectionFeedback(newRange)
            }
            textView.selectedRange = newRange
            _ = controller.recordParentMutation(reason: "legacyPendingInsertions")
            PromptEditorBridgeTelemetry.record(.legacyBindingWrite, [
                "binding": "attributedText",
                "length": mutable.length
            ])
            parent.attributedText = mutable
            PromptEditorBridgeTelemetry.record(.legacyBindingWrite, [
                "binding": "selectionRange",
                "location": newRange.location,
                "length": newRange.length
            ])
            parent.selectionRange = newRange
            updateHeight(for: textView, allowAutoScroll: false)
        }

        private func clamp(_ range: NSRange, length: Int) -> NSRange {
            guard range.location != NSNotFound else {
                return NSRange(location: length, length: 0)
            }
            let safeLocation = min(max(range.location, 0), length)
            let maxLength = max(0, min(range.length, length - safeLocation))
            return NSRange(location: safeLocation, length: maxLength)
        }
    }
}

// MARK: - Custom UITextView with image paste support

/// A UITextView subclass that supports pasting images from the clipboard.
///
/// Intercepts paste at three levels to prevent the default UITextView behaviour
/// of inserting raw image binary data as text (which freezes the UI):
///   1. `paste(_:)` – UIResponder action from the edit menu
///   2. `paste(itemProviders:)` – UITextPasteConfigurationSupporting
///   3. `UITextPasteDelegate.transforming` – item-level safety net that discards
///      image items before they can be converted to text
final class PastableTextView: UITextView, UITextPasteDelegate {
    var onPasteImages: (([UIImage]) -> Void)?
    var onEscape: (() -> Void)?
    var onEscapeLongPress: (() -> Void)?
    var onLayout: ((CGFloat) -> Void)?
    var onDirectUserTextReplacement: ((NSRange, String) -> Void)?
    var handlesMentionPickerKeyCommands = false
    var notificationVisibleCount = 0
    var keyboardOwnershipStore = KeyboardOwnershipStore()
    var onMentionPickerTab: (() -> Void)?
    var onMentionPickerMoveUp: (() -> Void)?
    var onMentionPickerMoveDown: (() -> Void)?
    var programmaticEditInFlight: Bool = false
    private var expectedProgrammaticSelectionFeedback: NSRange?
    var onResponderFocusChange: ((Bool) -> Void)?
    var isInputEnabled: Bool = true {
        didSet {
            guard oldValue != isInputEnabled else { return }
            isEditable = isInputEnabled
            isSelectable = isInputEnabled
            if !isInputEnabled && isFirstResponder {
                _ = resignFirstResponder()
            }
        }
    }

    /// Image providers collected during the delegate's `transforming` calls,
    /// flushed after the run-loop tick so all items from a single paste are batched.
    private var _delegateImageProviders: [NSItemProvider] = []

    /// Text providers collected during the delegate's `transforming` calls,
    /// flushed after the run-loop tick so all items from a single drop are batched.
    private var _delegateTextProviders: [NSItemProvider] = []
    private var escapeLongPressTask: Task<Void, Never>?
    private var isEscapePressed = false
    private var didFireEscapeLongPress = false
    private let escapeLongPressDuration: Duration = .milliseconds(700)

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        pasteDelegate = self
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        pasteDelegate = self
    }

    func expectProgrammaticSelectionFeedback(_ selection: NSRange) {
        expectedProgrammaticSelectionFeedback = selection
    }

    func consumeExpectedProgrammaticSelectionFeedback(_ selection: NSRange) -> Bool {
        guard let expectedProgrammaticSelectionFeedback,
              expectedProgrammaticSelectionFeedback == selection else {
            return false
        }
        self.expectedProgrammaticSelectionFeedback = nil
        return true
    }

    func clearExpectedProgrammaticSelectionFeedback() {
        expectedProgrammaticSelectionFeedback = nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?(bounds.width)
    }

        override func becomeFirstResponder() -> Bool {
            let didBecomeFirstResponder = super.becomeFirstResponder()
            if didBecomeFirstResponder {
            onResponderFocusChange?(true)
        }
        return didBecomeFirstResponder
    }

    override func resignFirstResponder() -> Bool {
        let didResignFirstResponder = super.resignFirstResponder()
        if didResignFirstResponder {
            onResponderFocusChange?(false)
        }
        return didResignFirstResponder
        }

    override var keyCommands: [UIKeyCommand]? {
        let base = Self.appFontScalePassthroughCommands(from: super.keyCommands ?? [])
        let emacsCommands = TextEditingShortcutContract.keyCommands(
            action: #selector(didPressTextEditingShortcut)
        )
        let appCommandShortcuts = ChatAppCommandShortcut
            .prioritizedTextInputKeyCommandSpecs(notificationVisibleCount: notificationVisibleCount)
            .filter { spec in
                guard let intent = KeyboardCommandBridge.intent(input: spec.input, modifierFlags: spec.modifierFlags) else {
                    return false
                }
                let outcome = KeyboardCommandRouter.route(intent: intent, store: keyboardOwnershipStore).outcome
                return outcome.containsNotificationBubble || outcome.containsHandledSurface(.transcript)
            }
            .map { spec in
                UIKeyCommand(
                    input: spec.input,
                    modifierFlags: spec.modifierFlags,
                    action: spec.action.selector
                )
            }
        let inputReleaseCommands = [
            UIKeyCommand(input: "\r", modifierFlags: [.shift], action: #selector(didPressModifiedReturn)),
            UIKeyCommand(input: "\r", modifierFlags: [.control], action: #selector(didPressModifiedReturn)),
            UIKeyCommand(input: "\n", modifierFlags: [.shift], action: #selector(didPressModifiedReturn)),
            UIKeyCommand(input: "\n", modifierFlags: [.control], action: #selector(didPressModifiedReturn)),
            UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(didPressEscape))
        ]
        let modifiedReturnCommands = KeyboardCommandBridge.textInputSpecs.compactMap { spec -> UIKeyCommand? in
            guard spec.intent == .textModifiedNewline else { return nil }
            return UIKeyCommand(
                input: spec.input,
                modifierFlags: spec.modifierFlags,
                action: #selector(didPressModifiedReturn)
            )
        }
        let mentionPickerCommands: [UIKeyCommand] = handlesMentionPickerKeyCommands
            ? KeyboardCommandBridge.pickerSpecs.compactMap { spec in
                guard let selector = mentionPickerSelector(for: spec.intent) else { return nil }
                return UIKeyCommand(
                    input: spec.input,
                    modifierFlags: spec.modifierFlags,
                    action: selector
                )
            }
            : []
        return mentionPickerCommands
            + appCommandShortcuts
            + inputReleaseCommands
            + modifiedReturnCommands
            + base
            + emacsCommands
    }

    static func appFontScalePassthroughCommands(from commands: [UIKeyCommand]) -> [UIKeyCommand] {
        commands.filter { command in
            !(command.modifierFlags == [.command] && (command.input == "-" || command.input == "="))
        }
    }

    private func mentionPickerSelector(for intent: KeyboardCommandIntent) -> Selector? {
        switch intent {
        case .pickerAccept:
            return #selector(didPressMentionPickerTab)
        case .pickerNavigateUp:
            return #selector(didPressMentionPickerUp)
        case .pickerNavigateDown:
            return #selector(didPressMentionPickerDown)
        default:
            return nil
        }
    }

    @objc private func didPressMentionPickerTab(_ sender: UIKeyCommand) {
        PromptEditorBridgeTelemetry.record(.commandCapture, ["route": "pickerAccept"])
        guard canHandleInputShortcut, routes(.pickerAccept) else { return }
        onMentionPickerTab?()
    }

    @objc private func didPressMentionPickerUp(_ sender: UIKeyCommand) {
        PromptEditorBridgeTelemetry.record(.commandCapture, ["route": "pickerNavigateUp"])
        guard canHandleInputShortcut, routes(.pickerNavigateUp) else { return }
        onMentionPickerMoveUp?()
    }

    @objc private func didPressMentionPickerDown(_ sender: UIKeyCommand) {
        PromptEditorBridgeTelemetry.record(.commandCapture, ["route": "pickerNavigateDown"])
        guard canHandleInputShortcut, routes(.pickerNavigateDown) else { return }
        onMentionPickerMoveDown?()
    }

    @objc private func didPressModifiedReturn(_ sender: UIKeyCommand) {
        PromptEditorBridgeTelemetry.record(.commandCapture, ["route": "textModifiedNewline"])
        guard canHandleInputShortcut,
              case .handled(.composer) = KeyboardCommandRouter
                .route(intent: .textModifiedNewline, store: keyboardOwnershipStore)
                .outcome else { return }
        PromptEditorBridgeTelemetry.record(.commandRoute, [
            "intent": "textModifiedNewline",
            "outcome": "composer"
        ])
        insertPlainText("\n")
    }

    @objc private func didPressEscape(_ sender: UIKeyCommand) {
        PromptEditorBridgeTelemetry.record(.commandCapture, ["route": "escape"])
        guard canHandleInputShortcut else { return }
        onEscape?()
    }

    private func routes(_ intent: KeyboardCommandIntent) -> Bool {
        guard handlesMentionPickerKeyCommands else { return false }
        let outcome = KeyboardCommandRouter.route(intent: intent, store: keyboardOwnershipStore).outcome
        PromptEditorBridgeTelemetry.record(.commandRoute, [
            "intent": String(describing: intent),
            "outcome": String(describing: outcome)
        ])
        guard case .handled(.mentionPicker) = outcome else { return false }
        return true
    }

    private var canHandleInputShortcut: Bool {
        isInputEnabled && isFirstResponder
    }

    @objc private func didPressTextEditingShortcut(_ sender: UIKeyCommand) {
        guard canHandleInputShortcut,
              let action = TextEditingShortcutContract.action(for: sender),
              case .handled(.composer) = KeyboardCommandRouter
                .route(intent: .textEditing, store: keyboardOwnershipStore)
                .outcome else { return }
        TextEditingShortcutContract.perform(action, in: self) { [weak self] range, replacement in
            self?.replaceUserText(range, with: replacement)
        }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard presses.contains(where: isEscapePress(_:)) else {
            guard canHandleInputShortcut else {
                super.pressesBegan(presses, with: event)
                return
            }
            for press in presses {
                guard let key = press.key, key.hasNoCommandModifiers else { continue }
                switch key.keyCode {
                case .keyboardUpArrow:
                    PromptEditorBridgeTelemetry.record(.commandCapture, ["route": "arrowUp"])
                    guard routes(.pickerNavigateUp) else { break }
                    onMentionPickerMoveUp?()
                    return
                case .keyboardDownArrow:
                    PromptEditorBridgeTelemetry.record(.commandCapture, ["route": "arrowDown"])
                    guard routes(.pickerNavigateDown) else { break }
                    onMentionPickerMoveDown?()
                    return
                default:
                    continue
                }
            }
            super.pressesBegan(presses, with: event)
            return
        }
        guard canHandleInputShortcut else { return }
        guard !isEscapePressed else { return }
        PromptEditorBridgeTelemetry.record(.commandCapture, ["route": "escapePress"])
        isEscapePressed = true
        didFireEscapeLongPress = false
        escapeLongPressTask?.cancel()
        escapeLongPressTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: escapeLongPressDuration)
            } catch is CancellationError {
                return
            } catch {
                return
            }
            await MainActor.run {
                guard self.isEscapePressed else { return }
                self.didFireEscapeLongPress = true
                self.onEscapeLongPress?()
            }
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard presses.contains(where: isEscapePress(_:)) else {
            super.pressesEnded(presses, with: event)
            return
        }
        escapeLongPressTask?.cancel()
        escapeLongPressTask = nil
        if !didFireEscapeLongPress {
            PromptEditorBridgeTelemetry.record(.commandRoute, [
                "intent": "escape",
                "outcome": "cancel"
            ])
            onEscape?()
        }
        isEscapePressed = false
        didFireEscapeLongPress = false
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard presses.contains(where: isEscapePress(_:)) else {
            super.pressesCancelled(presses, with: event)
            return
        }
        escapeLongPressTask?.cancel()
        escapeLongPressTask = nil
        isEscapePressed = false
        didFireEscapeLongPress = false
    }

    private func isEscapePress(_ press: UIPress) -> Bool {
        guard press.key != nil else { return false }
        return press.key?.charactersIgnoringModifiers == UIKeyCommand.inputEscape
    }

    // MARK: - Paste action gating

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)) {
            let pasteboard = UIPasteboard.general
            if pasteboard.hasImages || pasteboard.hasStrings {
                return true
            }
        }
        return super.canPerformAction(action, withSender: sender)
    }

    // MARK: - Primary paste entry points

    override func paste(_ sender: Any?) {
        let pasteboard = UIPasteboard.general
        let imageProviders = pasteboard.itemProviders.filter { Self.providerHasImage($0) }
        PromptEditorBridgeTelemetry.record(.commandCapture, [
            "route": "paste",
            "imageProviders": imageProviders.count
        ])
        logger.info("[paste] paste(_:) hasImages=\(pasteboard.hasImages) imageProviders=\(imageProviders.count)")
        guard !imageProviders.isEmpty else {
            // Strip rich formatting — insert only plain text with default typing attributes.
            if let plain = pasteboard.string, !plain.isEmpty {
                insertPlainText(plain)
            }
            return
        }
        handleImageProviders(imageProviders)
    }

    override func paste(itemProviders: [NSItemProvider]) {
        let imageProviders = itemProviders.filter { Self.providerHasImage($0) }
        PromptEditorBridgeTelemetry.record(.commandCapture, [
            "route": "pasteItemProviders",
            "imageProviders": imageProviders.count,
            "total": itemProviders.count
        ])
        logger.info("[paste] paste(itemProviders:) total=\(itemProviders.count) images=\(imageProviders.count)")
        guard !imageProviders.isEmpty else {
            handleTextProviders(itemProviders)
            return
        }
        handleImageProviders(imageProviders)
    }

    // MARK: - UITextPasteDelegate  (safety net)

    func textPasteConfigurationSupporting(
        _ textPasteConfigurationSupporting: UITextPasteConfigurationSupporting,
        transform item: UITextPasteItem
    ) {
        let isImage = Self.providerHasImage(item.itemProvider)
        logger.info("[paste] transforming item isImage=\(isImage) types=\(item.itemProvider.registeredTypeIdentifiers)")
        if isImage {
            // Prevent binary image data from ever being inserted as text.
            item.setNoResult()
            _delegateImageProviders.append(item.itemProvider)
            // Schedule a single flush after all items in this paste have been transformed.
            NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(_flushDelegateImages), object: nil)
            perform(#selector(_flushDelegateImages), with: nil, afterDelay: 0)
        } else {
            // Strip rich formatting — collect text providers and batch-insert.
            item.setNoResult()
            let provider = item.itemProvider
            if Self.providerHasText(provider) {
                _delegateTextProviders.append(provider)
                NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(_flushDelegateText), object: nil)
                perform(#selector(_flushDelegateText), with: nil, afterDelay: 0)
            }
        }
    }

    @objc private func _flushDelegateText() {
        let providers = _delegateTextProviders
        _delegateTextProviders = []
        guard !providers.isEmpty else { return }
        logger.info("[paste] delegate flush \(providers.count) text provider(s)")
        Task.detached { [weak self] in
            var texts: [String] = []
            for provider in providers {
                if let text = await Self.loadSanitizedText(from: provider) {
                    texts.append(text)
                }
            }
            let combined = texts.joined()
            await MainActor.run { [weak self, combined] in
                guard let self else { return }
                if !combined.isEmpty {
                    self.insertPlainText(combined)
                }
            }
        }
    }

    @objc private func _flushDelegateImages() {
        let providers = _delegateImageProviders
        _delegateImageProviders = []
        guard !providers.isEmpty else { return }
        logger.info("[paste] delegate flush \(providers.count) image provider(s)")
        handleImageProviders(providers)
    }

    // MARK: - Plain text insertion

    /// Inserts plain text at the current selection, replacing any selected text,
    /// using the text view's current `typingAttributes` (strips all rich formatting).
    private func insertPlainText(_ text: String) {
        let attributed = NSAttributedString(string: text, attributes: typingAttributes)
        let range = selectedRange
        notifyDirectUserTextReplacement(range: range, replacementText: text)
        textStorage.replaceCharacters(in: range, with: attributed)
        selectedRange = NSRange(location: range.location + attributed.length, length: 0)
        delegate?.textViewDidChange?(self)
    }

    private func replaceUserText(_ textRange: UITextRange, with replacementText: String) {
        notifyDirectUserTextReplacement(range: nsRange(from: textRange), replacementText: replacementText)
        replace(textRange, withText: replacementText)
    }

    private func notifyDirectUserTextReplacement(range: NSRange, replacementText: String) {
        guard !programmaticEditInFlight else { return }
        clearExpectedProgrammaticSelectionFeedback()
        onDirectUserTextReplacement?(range, replacementText)
    }

    private func nsRange(from textRange: UITextRange) -> NSRange {
        let location = offset(from: beginningOfDocument, to: textRange.start)
        let length = offset(from: textRange.start, to: textRange.end)
        return NSRange(location: location, length: length)
    }

    nonisolated private static func loadSanitizedText(from provider: NSItemProvider) async -> String? {
        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            return await loadText(for: UTType.plainText.identifier, from: provider)
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.utf8PlainText.identifier) {
            return await loadText(for: UTType.utf8PlainText.identifier, from: provider)
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.text.identifier) {
            return await loadText(for: UTType.text.identifier, from: provider)
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.rtf.identifier) {
            if let data = await loadData(for: UTType.rtf.identifier, from: provider),
               let attributed = try? NSAttributedString(
                    data: data,
                    options: [.documentType: NSAttributedString.DocumentType.rtf],
                    documentAttributes: nil
               ) {
                return attributed.string
            }
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.html.identifier) {
            if let data = await loadData(for: UTType.html.identifier, from: provider),
               let attributed = try? NSAttributedString(
                    data: data,
                    options: [.documentType: NSAttributedString.DocumentType.html],
                    documentAttributes: nil
               ) {
                return attributed.string
            }
        }
        return nil
    }

    nonisolated private static func loadText(for typeIdentifier: String, from provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { obj, _ in
                let text = (obj as? String) ?? (obj as? Data).flatMap { String(data: $0, encoding: .utf8) }
                continuation.resume(returning: text)
            }
        }
    }

    nonisolated private static func loadData(for typeIdentifier: String, from provider: NSItemProvider) async -> Data? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { obj, _ in
                let data = (obj as? Data) ?? (obj as? String).flatMap { $0.data(using: .utf8) }
                continuation.resume(returning: data)
            }
        }
    }

    nonisolated private static func providerHasText(_ provider: NSItemProvider) -> Bool {
        provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
            || provider.hasItemConformingToTypeIdentifier(UTType.utf8PlainText.identifier)
            || provider.hasItemConformingToTypeIdentifier(UTType.text.identifier)
            || provider.hasItemConformingToTypeIdentifier(UTType.rtf.identifier)
            || provider.hasItemConformingToTypeIdentifier(UTType.html.identifier)
    }

    // MARK: - Image detection

    nonisolated private static func providerHasImage(_ provider: NSItemProvider) -> Bool {
        provider.canLoadObject(ofClass: UIImage.self)
            || provider.hasItemConformingToTypeIdentifier(UTType.image.identifier)
    }

    private func handleTextProviders(_ providers: [NSItemProvider]) {
        Task.detached { [weak self] in
            var texts: [String] = []
            for provider in providers where Self.providerHasText(provider) {
                if let text = await Self.loadSanitizedText(from: provider) {
                    texts.append(text)
                }
            }
            let combined = texts.joined()
            await MainActor.run { [weak self, combined] in
                guard let self else { return }
                if !combined.isEmpty {
                    self.insertPlainText(combined)
                }
            }
        }
    }

    // MARK: - Async image loading

    private func handleImageProviders(_ imageProviders: [NSItemProvider]) {
        Task.detached { [weak self] in
            let images = await Self.loadImages(from: imageProviders)
            await MainActor.run { [weak self, images] in
                guard let self else { return }
                logger.info("[paste] loaded \(images.count) image(s)")
                self.onPasteImages?(images)
            }
        }
    }

    nonisolated private static func loadImages(from providers: [NSItemProvider]) async -> [UIImage] {
        await withTaskGroup(of: UIImage?.self) { group in
            for provider in providers {
                group.addTask {
                    // Try the high-level UIImage loader first, fall back to raw data.
                    if provider.canLoadObject(ofClass: UIImage.self) {
                        return await withCheckedContinuation { continuation in
                            provider.loadObject(ofClass: UIImage.self) { object, _ in
                                continuation.resume(returning: object as? UIImage)
                            }
                        }
                    } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                        return await withCheckedContinuation { continuation in
                            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                                continuation.resume(returning: data.flatMap { UIImage(data: $0) })
                            }
                        }
                    }
                    return nil
                }
            }
            var images: [UIImage] = []
            for await image in group {
                if let image { images.append(image) }
            }
            return images
        }
    }
}
