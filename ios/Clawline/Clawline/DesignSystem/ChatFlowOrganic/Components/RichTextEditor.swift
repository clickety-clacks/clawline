//
//  RichTextEditor.swift
//  Clawline
//
//  Created by Codex on 1/15/26.
//

import SwiftUI
import UIKit

struct RichTextEditor: UIViewRepresentable {
    @Binding var attributedText: NSAttributedString
    @Binding var calculatedHeight: CGFloat
    @Binding var selectionRange: NSRange
    var focusTrigger: Int
    var isEditable: Bool
    var onFocusChange: (Bool) -> Void
    var trailingPadding: CGFloat = 20

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 10, left: 20, bottom: 10, right: trailingPadding)
        textView.textContainer.lineFragmentPadding = 0
        textView.adjustsFontForContentSizeCategory = true
        textView.font = UIFont.preferredFont(forTextStyle: .body)
        textView.allowsEditingTextAttributes = true
        textView.keyboardDismissMode = .interactive
        textView.tintColor = UIColor.label
        textView.autocorrectionType = .yes
        textView.smartQuotesType = .yes
        textView.smartDashesType = .yes
        textView.smartInsertDeleteType = .yes
        textView.attributedText = attributedText
        textView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.parent = self

        if !(textView.attributedText?.isEqual(attributedText) ?? false) {
            textView.attributedText = attributedText
        }

        if textView.selectedRange != selectionRange && selectionRange.location != NSNotFound {
            textView.selectedRange = selectionRange
        }

        if textView.isEditable != isEditable {
            textView.isEditable = isEditable
            if !isEditable {
                textView.resignFirstResponder()
            }
        }

        let currentInset = textView.textContainerInset
        if abs(currentInset.right - trailingPadding) > 0.5 {
            textView.textContainerInset = UIEdgeInsets(top: currentInset.top,
                                                       left: currentInset.left,
                                                       bottom: currentInset.bottom,
                                                       right: trailingPadding)
        }

        context.coordinator.applyFocusIfNeeded(on: textView, trigger: focusTrigger)
        context.coordinator.updateHeight(for: textView)
        context.coordinator.ensureTypingAttributes(on: textView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: RichTextEditor
        private var lastFocusTrigger: Int = 0

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
            parent.attributedText = textView.attributedText
            parent.selectionRange = textView.selectedRange
            updateHeight(for: textView)
            ensureCaretVisible(in: textView)
            ensureTypingAttributes(on: textView)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard textView.selectedRange.location != NSNotFound else { return }
            parent.selectionRange = textView.selectedRange
            ensureCaretVisible(in: textView)
            ensureTypingAttributes(on: textView)
        }

        func updateHeight(for textView: UITextView) {
            let targetWidth = textView.bounds.width
            let screenWidth = textView.window?.windowScene?.screen.bounds.width ?? textView.bounds.width
            let fallbackWidth = screenWidth > 0 ? screenWidth : 390
            let referenceWidth = targetWidth > 0 ? targetWidth : fallbackWidth - 48
            let fittingSize = CGSize(width: referenceWidth,
                                     height: .greatestFiniteMagnitude)
            let size = textView.sizeThatFits(fittingSize)
            let minHeight: CGFloat = 44
            let maxHeight: CGFloat = 112
            let clamped = min(max(size.height, minHeight), maxHeight)
            if abs(parent.calculatedHeight - clamped) > 0.5 {
                parent.calculatedHeight = clamped
            }
            textView.isScrollEnabled = size.height > maxHeight
            if textView.isScrollEnabled {
                ensureCaretVisible(in: textView)
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

        func ensureTypingAttributes(on textView: UITextView) {
            var attributes = textView.typingAttributes
            attributes[.font] = UIFont.preferredFont(forTextStyle: .body)
            attributes[.foregroundColor] = UIColor.label
            textView.typingAttributes = attributes
        }
    }
}
