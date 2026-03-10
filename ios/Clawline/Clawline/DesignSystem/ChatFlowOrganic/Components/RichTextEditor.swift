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

struct RichTextEditor: UIViewRepresentable {
    @Binding var attributedText: NSAttributedString
    @Binding var calculatedHeight: CGFloat
    @Binding var selectionRange: NSRange
    @Binding var pendingInsertions: [PendingAttachment]
    var resetToken: Int
    var focusTrigger: Int
    var isEditable: Bool
    var tintColor: UIColor
    var textColor: UIColor = .label
    var onFocusChange: (Bool) -> Void
    var onSubmit: (() -> Void)?
    var onPasteImages: (([UIImage]) -> Void)?
    var trailingPadding: CGFloat = 20

    func makeUIView(context: Context) -> PastableTextView {
        let textView = PastableTextView()
        textView.delegate = context.coordinator
        let coordinator = context.coordinator
        textView.onPasteImages = { images in
            coordinator.parent.onPasteImages?(images)
        }
        textView.onLayout = { _ in
            coordinator.updateHeight(for: textView, allowAutoScroll: false)
        }
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 20, bottom: 12, right: trailingPadding)
        textView.textContainer.lineFragmentPadding = 0
        textView.adjustsFontForContentSizeCategory = true
        textView.font = UIFont.preferredFont(forTextStyle: .body)
        textView.allowsEditingTextAttributes = true
#if !os(visionOS)
        textView.keyboardDismissMode = .interactive
#endif
        textView.returnKeyType = .send
        textView.tintColor = tintColor
        textView.textColor = textColor
        textView.autocorrectionType = .yes
        textView.smartQuotesType = .yes
        textView.smartDashesType = .yes
        textView.smartInsertDeleteType = .yes
        textView.attributedText = attributedText
        textView.isInputEnabled = isEditable
        textView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return textView
    }

    func updateUIView(_ textView: PastableTextView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.isUpdatingFromSwiftUI = true
        defer { context.coordinator.isUpdatingFromSwiftUI = false }

        // Update paste callback
        let coordinator = context.coordinator
        textView.onPasteImages = { images in
            coordinator.parent.onPasteImages?(images)
        }
        textView.onLayout = { _ in
            coordinator.updateHeight(for: textView, allowAutoScroll: false)
        }

        let isComposing = textView.markedTextRange != nil
        if resetToken != context.coordinator.lastResetToken, !isComposing {
            context.coordinator.lastResetToken = resetToken
            textView.attributedText = attributedText
            context.coordinator.enforceBaseAttributes(on: textView)
            if selectionRange.location != NSNotFound, textView.selectedRange != selectionRange {
                context.coordinator.isApplyingParentSelection = true
                textView.selectedRange = selectionRange
                context.coordinator.isApplyingParentSelection = false
            }
            logger.info("[trace] updateUIView applied reset len=\(attributedText.length)")
        }
        context.coordinator.isApplyingLocalEdit = false

        if textView.isInputEnabled != isEditable {
            textView.isInputEnabled = isEditable
        }

        if textView.tintColor != tintColor {
            textView.tintColor = tintColor
        }
        if textView.textColor != textColor {
            textView.textColor = textColor
        }

        let currentInset = textView.textContainerInset
        if abs(currentInset.right - trailingPadding) > 0.5 {
            textView.textContainerInset = UIEdgeInsets(top: currentInset.top,
                                                       left: currentInset.left,
                                                       bottom: currentInset.bottom,
                                                       right: trailingPadding)
        }

        context.coordinator.applyFocusIfNeeded(on: textView, trigger: focusTrigger)
        context.coordinator.updateHeight(for: textView, allowAutoScroll: false)
        context.coordinator.enforceBaseAttributesIfNeeded(on: textView)
        context.coordinator.ensureTypingAttributes(on: textView)

        if !pendingInsertions.isEmpty, !isComposing, !context.coordinator.isInsertingAttachments {
            context.coordinator.isInsertingAttachments = true
            let attachments = pendingInsertions
            context.coordinator.insertAttachments(attachments, into: textView)
            DispatchQueue.main.async {
                self.pendingInsertions = []
                context.coordinator.isInsertingAttachments = false
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: RichTextEditor
        private var lastFocusTrigger: Int = 0
        var isApplyingLocalEdit = false
        var isInsertingAttachments = false
        var isUpdatingFromSwiftUI = false
        var isApplyingParentSelection = false
        var lastResetToken: Int = 0
        private var lastBaseTextColor: UIColor?

        init(parent: RichTextEditor) {
            self.parent = parent
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            parent.onFocusChange(true)
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            parent.onFocusChange(false)
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !isUpdatingFromSwiftUI else { return }
            isApplyingLocalEdit = true
            parent.attributedText = textView.attributedText
            setSelectionRange(textView.selectedRange)
            updateHeight(for: textView, allowAutoScroll: true)
            ensureCaretVisible(in: textView)
            ensureTypingAttributes(on: textView)
            let length = textView.attributedText?.length ?? 0
            logger.info("[trace] textViewDidChange len=\(length) sel=\(textView.selectedRange.location),\(textView.selectedRange.length)")
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            let selectedRange = textView.selectedRange
            guard selectedRange.location != NSNotFound else { return }
            guard !isApplyingParentSelection else { return }
            setSelectionRange(selectedRange)
            if isApplyingLocalEdit {
                ensureCaretVisible(in: textView)
            }
            ensureTypingAttributes(on: textView)
        }

        func textView(_ textView: UITextView,
                      shouldChangeTextIn range: NSRange,
                      replacementText text: String) -> Bool {
            if text == "\n" {
                parent.onSubmit?()
                return false
            }
            return true
        }

        func updateHeight(for textView: UITextView, allowAutoScroll: Bool) {
            let targetWidth = textView.bounds.width
            guard targetWidth > 1 else {
                DispatchQueue.main.async { [weak self, weak textView] in
                    guard let self, let textView else { return }
                    self.updateHeight(for: textView, allowAutoScroll: allowAutoScroll)
                }
                return
            }
            let referenceWidth = targetWidth
            let fittingSize = CGSize(width: referenceWidth,
                                     height: .greatestFiniteMagnitude)
            let size = textView.sizeThatFits(fittingSize)
            let minHeight: CGFloat = 44
            let maxHeight: CGFloat = 120
            let lineHeight = textView.font?.lineHeight ?? 17
            let singleLineHeight = lineHeight + textView.textContainerInset.top + textView.textContainerInset.bottom
            let clamped: CGFloat
            if size.height <= singleLineHeight + lineHeight * 0.5 {
                clamped = minHeight
            } else {
                clamped = min(max(size.height, minHeight), maxHeight)
            }
            if abs(parent.calculatedHeight - clamped) > 0.5 {
                if isUpdatingFromSwiftUI {
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        guard abs(self.parent.calculatedHeight - clamped) > 0.5 else { return }
                        self.parent.calculatedHeight = clamped
                    }
                } else {
                    parent.calculatedHeight = clamped
                }
            }
            textView.isScrollEnabled = size.height > maxHeight
            if textView.isScrollEnabled {
                if allowAutoScroll {
                    ensureCaretVisible(in: textView)
                }
            }
        }

        func applyFocusIfNeeded(on textView: UITextView, trigger: Int) {
            guard trigger != lastFocusTrigger else { return }
            lastFocusTrigger = trigger
            guard trigger > 0 else { return }
            guard parent.isEditable else { return }
            textView.becomeFirstResponder()
        }

        private func ensureCaretVisible(in textView: UITextView) {
            guard textView.isScrollEnabled else { return }
            let range = textView.selectedRange
            DispatchQueue.main.async {
                textView.scrollRangeToVisible(range)
            }
        }

        private func setSelectionRange(_ selectedRange: NSRange) {
            guard parent.selectionRange != selectedRange else { return }
            if isUpdatingFromSwiftUI {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    guard self.parent.selectionRange != selectedRange else { return }
                    self.parent.selectionRange = selectedRange
                }
            } else {
                parent.selectionRange = selectedRange
            }
        }

        func ensureTypingAttributes(on textView: UITextView) {
            var attributes = textView.typingAttributes
            attributes[.font] = UIFont.preferredFont(forTextStyle: .body)
            attributes[.foregroundColor] = parent.textColor
            textView.typingAttributes = attributes
        }

        func enforceBaseAttributesIfNeeded(on textView: UITextView) {
            if let lastBaseTextColor, lastBaseTextColor.isEqual(parent.textColor) {
                return
            }
            lastBaseTextColor = parent.textColor
            enforceBaseAttributes(on: textView)
        }

        func enforceBaseAttributes(on textView: UITextView) {
            let baseFont = UIFont.preferredFont(forTextStyle: .body)
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
            textView.selectedRange = newRange
            parent.attributedText = mutable
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
    var onLayout: ((CGFloat) -> Void)?
    var isInputEnabled: Bool = true {
        didSet {
            guard oldValue != isInputEnabled else { return }
            isEditable = isInputEnabled
            isSelectable = isInputEnabled
            if !isInputEnabled && isFirstResponder {
                resignFirstResponder()
            }
        }
    }

    /// Image providers collected during the delegate's `transforming` calls,
    /// flushed after the run-loop tick so all items from a single paste are batched.
    private var _delegateImageProviders: [NSItemProvider] = []

    /// Text providers collected during the delegate's `transforming` calls,
    /// flushed after the run-loop tick so all items from a single drop are batched.
    private var _delegateTextProviders: [NSItemProvider] = []

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        pasteDelegate = self
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        pasteDelegate = self
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?(bounds.width)
    }

    override var keyCommands: [UIKeyCommand]? {
        let base = super.keyCommands ?? []
        let emacsCommands: [UIKeyCommand] = [
            UIKeyCommand(input: "a", modifierFlags: [.control], action: #selector(didPressCtrlA)),
            UIKeyCommand(input: "e", modifierFlags: [.control], action: #selector(didPressCtrlE)),
            UIKeyCommand(input: "w", modifierFlags: [.control], action: #selector(didPressCtrlW)),
            UIKeyCommand(input: "u", modifierFlags: [.control], action: #selector(didPressCtrlU)),
            UIKeyCommand(input: "k", modifierFlags: [.control], action: #selector(didPressCtrlK)),
            UIKeyCommand(input: "c", modifierFlags: [.control], action: #selector(didPressCtrlC))
        ]
        return base + emacsCommands
    }

    private var canHandleInputShortcut: Bool {
        isInputEnabled && isFirstResponder
    }

    @objc private func didPressCtrlA(_ sender: UIKeyCommand) {
        guard canHandleInputShortcut else { return }
        selectedTextRange = textRange(from: beginningOfDocument, to: beginningOfDocument)
    }

    @objc private func didPressCtrlE(_ sender: UIKeyCommand) {
        guard canHandleInputShortcut else { return }
        selectedTextRange = textRange(from: endOfDocument, to: endOfDocument)
    }

    @objc private func didPressCtrlW(_ sender: UIKeyCommand) {
        guard canHandleInputShortcut else { return }

        if let selectedRange = selectedTextRange, !selectedRange.isEmpty {
            replace(selectedRange, withText: "")
            return
        }

        guard let cursor = selectedTextRange?.start else { return }
        guard let textBeforeCursorRange = textRange(from: beginningOfDocument, to: cursor),
              let textBeforeCursor = text(in: textBeforeCursorRange),
              !textBeforeCursor.isEmpty else { return }

        var deleteStartIndex = textBeforeCursor.endIndex
        while deleteStartIndex > textBeforeCursor.startIndex {
            let previousIndex = textBeforeCursor.index(before: deleteStartIndex)
            if !textBeforeCursor[previousIndex].isWhitespace { break }
            deleteStartIndex = previousIndex
        }

        while deleteStartIndex > textBeforeCursor.startIndex {
            let previousIndex = textBeforeCursor.index(before: deleteStartIndex)
            if textBeforeCursor[previousIndex].isWhitespace { break }
            deleteStartIndex = previousIndex
        }

        let charsToDelete = textBeforeCursor.distance(from: deleteStartIndex, to: textBeforeCursor.endIndex)
        guard charsToDelete > 0,
              let deleteStart = position(from: cursor, offset: -charsToDelete),
              let deleteRange = textRange(from: deleteStart, to: cursor) else { return }

        replace(deleteRange, withText: "")
    }

    @objc private func didPressCtrlU(_ sender: UIKeyCommand) {
        guard canHandleInputShortcut else { return }
        guard let cursor = selectedTextRange?.start,
              let range = textRange(from: beginningOfDocument, to: cursor),
              !range.isEmpty else { return }
        replace(range, withText: "")
    }

    @objc private func didPressCtrlK(_ sender: UIKeyCommand) {
        guard canHandleInputShortcut else { return }
        guard let cursor = selectedTextRange?.start,
              let range = textRange(from: cursor, to: endOfDocument),
              !range.isEmpty else { return }
        replace(range, withText: "")
    }

    @objc private func didPressCtrlC(_ sender: UIKeyCommand) {
        guard canHandleInputShortcut else { return }
        guard let fullRange = textRange(from: beginningOfDocument, to: endOfDocument) else { return }
        replace(fullRange, withText: "")
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
        transforming item: UITextPasteItem
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
            await MainActor.run {
                guard let self else { return }
                let combined = texts.joined()
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
        textStorage.replaceCharacters(in: range, with: attributed)
        selectedRange = NSRange(location: range.location + attributed.length, length: 0)
        delegate?.textViewDidChange?(self)
    }

    private static func loadSanitizedText(from provider: NSItemProvider) async -> String? {
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

    private static func loadText(for typeIdentifier: String, from provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { obj, _ in
                let text = (obj as? String) ?? (obj as? Data).flatMap { String(data: $0, encoding: .utf8) }
                continuation.resume(returning: text)
            }
        }
    }

    private static func loadData(for typeIdentifier: String, from provider: NSItemProvider) async -> Data? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { obj, _ in
                let data = (obj as? Data) ?? (obj as? String).flatMap { $0.data(using: .utf8) }
                continuation.resume(returning: data)
            }
        }
    }

    private static func providerHasText(_ provider: NSItemProvider) -> Bool {
        provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
            || provider.hasItemConformingToTypeIdentifier(UTType.utf8PlainText.identifier)
            || provider.hasItemConformingToTypeIdentifier(UTType.text.identifier)
            || provider.hasItemConformingToTypeIdentifier(UTType.rtf.identifier)
            || provider.hasItemConformingToTypeIdentifier(UTType.html.identifier)
    }

    // MARK: - Image detection

    private static func providerHasImage(_ provider: NSItemProvider) -> Bool {
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
            await MainActor.run {
                guard let self else { return }
                let combined = texts.joined()
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
            await MainActor.run {
                guard let self else { return }
                logger.info("[paste] loaded \(images.count) image(s)")
                self.onPasteImages?(images)
            }
        }
    }

    private static func loadImages(from providers: [NSItemProvider]) async -> [UIImage] {
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
