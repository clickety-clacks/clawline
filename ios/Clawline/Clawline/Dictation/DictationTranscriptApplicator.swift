//
//  DictationTranscriptApplicator.swift
//  Clawline
//
//  Created by Codex on 2/13/26.
//

import Foundation
import UIKit

struct ComposeDraftSnapshot {
    var content: NSAttributedString
    var attachments: [UUID: PendingAttachment]

    static let empty = ComposeDraftSnapshot(content: NSAttributedString(string: ""), attachments: [:])
}

@MainActor
protocol DictationComposeDraftHosting: AnyObject {
    var activeSessionKey: String { get }

    func captureComposeDraftSnapshot(for sessionKey: String) -> ComposeDraftSnapshot
    func applyComposeDraftDelta(
        baseSnapshot: ComposeDraftSnapshot,
        previousTranscriptUTF16Length: Int,
        replacementText: NSAttributedString,
        to sessionKey: String,
        moveCursorToEnd: Bool
    )
    func applyComposeDraftSnapshot(
        _ snapshot: ComposeDraftSnapshot,
        to sessionKey: String,
        moveCursorToEnd: Bool,
        announceEditorReset: Bool
    )
}

struct DictationTextApplicationPlan {
    let sessionKey: String
    let baseSnapshot: ComposeDraftSnapshot
    let replacementRange: NSRange
    let fallbackLocation: Int
    let replacementText: NSAttributedString
    let moveCursorToEnd: Bool
}

@MainActor
final class DictationTranscriptApplicator {
    private enum BoundaryAffinity {
        case start
        case end
    }

    private weak var host: (any DictationComposeDraftHosting)?
    private weak var composeTextView: PastableTextView?
    private var replayPlanProvider: (@MainActor () -> DictationTextApplicationPlan?)?

    init(host: any DictationComposeDraftHosting) {
        self.host = host
    }

    var boundComposeTextView: PastableTextView? {
        composeTextView
    }

    func setReplayPlanProvider(_ provider: @escaping @MainActor () -> DictationTextApplicationPlan?) {
        replayPlanProvider = provider
    }

    func captureSnapshot(for sessionKey: String) -> ComposeDraftSnapshot {
        host?.captureComposeDraftSnapshot(for: sessionKey) ?? .empty
    }

    func setComposeTextView(_ textView: PastableTextView?) {
        composeTextView = textView
        guard textView != nil, let replayPlan = replayPlanProvider?() else { return }
        apply(replayPlan)
    }

    func focusComposeTextView() {
        guard let composeTextView else { return }
        if !composeTextView.isFirstResponder {
            composeTextView.becomeFirstResponder()
        }
    }

    func dismissComposeTextViewKeyboard() {
        composeTextView?.resignFirstResponder()
        composeTextView?.window?.endEditing(true)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    func apply(_ plan: DictationTextApplicationPlan) {
        guard !plan.sessionKey.isEmpty else { return }
        guard host?.activeSessionKey == plan.sessionKey else { return }

        if let textView = composeTextView {
            let safeRange = safeReplacementRange(
                selectedRange: plan.replacementRange,
                textLength: textView.attributedText.length,
                fallbackLocation: plan.fallbackLocation
            )
            replaceText(
                in: textView,
                range: safeRange,
                with: plan.replacementText.string,
                moveCursorToEnd: plan.moveCursorToEnd
            )
            return
        }

        guard let host else { return }
        let currentSnapshot = host.captureComposeDraftSnapshot(for: plan.sessionKey)
        let current = NSMutableAttributedString(attributedString: currentSnapshot.content)
        let safeRange = safeReplacementRange(
            selectedRange: plan.replacementRange,
            textLength: current.length,
            fallbackLocation: plan.fallbackLocation
        )

        if safeRange.location + safeRange.length <= current.length {
            current.replaceCharacters(in: safeRange, with: plan.replacementText)
            host.applyComposeDraftSnapshot(
                ComposeDraftSnapshot(content: current, attachments: currentSnapshot.attachments),
                to: plan.sessionKey,
                moveCursorToEnd: plan.moveCursorToEnd,
                announceEditorReset: false
            )
            return
        }

        let fallback = NSMutableAttributedString(attributedString: plan.baseSnapshot.content)
        if plan.replacementText.length > 0 {
            fallback.append(plan.replacementText)
        }
        host.applyComposeDraftSnapshot(
            ComposeDraftSnapshot(content: fallback, attachments: plan.baseSnapshot.attachments),
            to: plan.sessionKey,
            moveCursorToEnd: plan.moveCursorToEnd,
            announceEditorReset: false
        )
    }

    func restore(snapshot: ComposeDraftSnapshot, to sessionKey: String) {
        host?.applyComposeDraftSnapshot(
            snapshot,
            to: sessionKey,
            moveCursorToEnd: false,
            announceEditorReset: true
        )
    }

    private func safeReplacementRange(selectedRange: NSRange, textLength: Int, fallbackLocation: Int) -> NSRange {
        let replacementLength = selectedRange.location == NSNotFound ? 0 : selectedRange.length
        let location = selectedRange.location == NSNotFound
            ? min(max(fallbackLocation, 0), textLength)
            : min(max(selectedRange.location, 0), textLength)
        let length = min(max(replacementLength, 0), max(0, textLength - location))
        return NSRange(location: location, length: length)
    }

    private func replaceText(
        in textView: UITextView,
        range: NSRange,
        with text: String,
        moveCursorToEnd: Bool
    ) {
        guard let textRange = textRange(in: textView, nsRange: range) else { return }
        if let textView = textView as? PastableTextView {
            let replacementLength = text.utf16.count
            let preservedSelection = preservedSelectionRange(
                currentSelection: textView.selectedRange,
                replacing: range,
                replacementUTF16Length: replacementLength,
                moveCursorToEnd: moveCursorToEnd
            )
            textView.beginDictationProgrammaticUpdate()
            defer { textView.endDictationProgrammaticUpdate() }
            textView.replace(textRange, withText: text)
            if textView.selectedRange != preservedSelection {
                textView.selectedRange = preservedSelection
            }
            textView.lastProgrammaticSelection = textView.selectedRange
            return
        }
        textView.replace(textRange, withText: text)
    }

    private func preservedSelectionRange(
        currentSelection: NSRange,
        replacing editedRange: NSRange,
        replacementUTF16Length: Int,
        moveCursorToEnd: Bool
    ) -> NSRange {
        let selection = sanitizedSelectionRange(currentSelection)
        guard selection.location != NSNotFound else {
            let replacementEnd = editedRange.location + replacementUTF16Length
            return NSRange(
                location: moveCursorToEnd ? replacementEnd : editedRange.location,
                length: 0
            )
        }

        if selection.length == 0 {
            let newLocation = transformCaretBoundary(
                selection.location,
                editedRange: editedRange,
                replacementUTF16Length: replacementUTF16Length,
                moveCursorToEnd: moveCursorToEnd
            )
            return NSRange(location: newLocation, length: 0)
        }

        let selectionStart = transformBoundary(
            selection.location,
            editedRange: editedRange,
            replacementUTF16Length: replacementUTF16Length,
            affinity: .start
        )
        let selectionEnd = transformBoundary(
            selection.location + selection.length,
            editedRange: editedRange,
            replacementUTF16Length: replacementUTF16Length,
            affinity: .end
        )
        return NSRange(
            location: selectionStart,
            length: max(0, selectionEnd - selectionStart)
        )
    }

    private func sanitizedSelectionRange(_ range: NSRange) -> NSRange {
        guard range.location != NSNotFound else {
            return NSRange(location: NSNotFound, length: 0)
        }
        return NSRange(location: max(0, range.location), length: max(0, range.length))
    }

    private func transformCaretBoundary(
        _ boundary: Int,
        editedRange: NSRange,
        replacementUTF16Length: Int,
        moveCursorToEnd: Bool
    ) -> Int {
        let editStart = editedRange.location
        let editEnd = editedRange.location + editedRange.length
        let delta = replacementUTF16Length - editedRange.length

        if boundary < editStart {
            return boundary
        }
        if boundary > editEnd {
            return boundary + delta
        }

        return moveCursorToEnd ? editStart + replacementUTF16Length : editStart
    }

    private func transformBoundary(
        _ boundary: Int,
        editedRange: NSRange,
        replacementUTF16Length: Int,
        affinity: BoundaryAffinity
    ) -> Int {
        let editStart = editedRange.location
        let editEnd = editedRange.location + editedRange.length
        let delta = replacementUTF16Length - editedRange.length

        if boundary < editStart {
            return boundary
        }
        if boundary > editEnd {
            return boundary + delta
        }

        switch affinity {
        case .start:
            return editStart
        case .end:
            return editStart + replacementUTF16Length
        }
    }

    private func textRange(in textView: UITextView, nsRange: NSRange) -> UITextRange? {
        guard let start = textView.position(from: textView.beginningOfDocument, offset: nsRange.location),
              let end = textView.position(from: start, offset: nsRange.length) else {
            return nil
        }
        return textView.textRange(from: start, to: end)
    }
}
