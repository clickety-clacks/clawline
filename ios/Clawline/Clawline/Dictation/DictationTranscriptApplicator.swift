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

enum DictationSelectionPolicy: Equatable {
    case preserveUserSelection
    case followTranscriptEndWhenSelectionAlreadyAtEnd
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
    let selectionPolicy: DictationSelectionPolicy
}

@MainActor
final class DictationTranscriptApplicator {
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
        let previousTextView = composeTextView
        let previousSelection = previousTextView?.selectedRange
        composeTextView = textView
        guard previousTextView !== textView else { return }
        if let textView,
           let previousSelection,
           previousSelection.location != NSNotFound {
            textView.selectedRange = safeReplacementRange(
                selectedRange: previousSelection,
                textLength: textView.attributedText.length,
                fallbackLocation: textView.attributedText.length
            )
        }
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
                selectionPolicy: plan.selectionPolicy
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
                moveCursorToEnd: plan.selectionPolicy == .followTranscriptEndWhenSelectionAlreadyAtEnd,
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
            moveCursorToEnd: plan.selectionPolicy == .followTranscriptEndWhenSelectionAlreadyAtEnd,
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
        guard host?.activeSessionKey == sessionKey,
              let composeTextView else { return }
        replaceSnapshot(snapshot, in: composeTextView)
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
        selectionPolicy: DictationSelectionPolicy
    ) {
        guard let textRange = textRange(in: textView, nsRange: range) else { return }
        let selectionAfterReplacement = transformedSelection(
            textView.selectedRange,
            replacing: range,
            replacementUTF16Length: (text as NSString).length,
            textLength: textView.attributedText.length,
            selectionPolicy: selectionPolicy
        )
        if let pastable = textView as? PastableTextView {
            pastable.dictationProgrammaticEditInFlight = true
            pastable.expectDictationProgrammaticSelectionFeedback(selectionAfterReplacement)
            textView.replace(textRange, withText: text)
            if textView.selectedRange != selectionAfterReplacement {
                textView.selectedRange = selectionAfterReplacement
            }
            pastable.dictationProgrammaticEditInFlight = false
            return
        }
        textView.replace(textRange, withText: text)
        if textView.selectedRange != selectionAfterReplacement {
            textView.selectedRange = selectionAfterReplacement
        }
    }

    private func replaceSnapshot(_ snapshot: ComposeDraftSnapshot, in textView: UITextView) {
        let location = snapshot.content.length
        let selection = NSRange(location: location, length: 0)
        if let pastable = textView as? PastableTextView {
            pastable.dictationProgrammaticEditInFlight = true
            pastable.expectDictationProgrammaticSelectionFeedback(selection)
            textView.attributedText = snapshot.content
        } else {
            textView.attributedText = snapshot.content
        }
        if textView.selectedRange != selection {
            textView.selectedRange = selection
        }
        if let pastable = textView as? PastableTextView {
            pastable.dictationProgrammaticEditInFlight = false
        }
    }

    private func transformedSelection(
        _ selection: NSRange,
        replacing range: NSRange,
        replacementUTF16Length: Int,
        textLength: Int,
        selectionPolicy: DictationSelectionPolicy
    ) -> NSRange {
        let safeSelection = safeReplacementRange(
            selectedRange: selection,
            textLength: textLength,
            fallbackLocation: textLength
        )
        let safeRange = safeReplacementRange(
            selectedRange: range,
            textLength: textLength,
            fallbackLocation: textLength
        )
        let replacementEnd = safeRange.location + replacementUTF16Length
        let selectionStart = safeSelection.location
        let selectionEnd = safeSelection.location + safeSelection.length

        if selectionPolicy == .followTranscriptEndWhenSelectionAlreadyAtEnd,
           safeSelection.length == 0,
           selectionStart == safeRange.location + safeRange.length {
            return NSRange(location: replacementEnd, length: 0)
        }

        let newStart = transformSelectionBoundary(
            selectionStart,
            replacing: safeRange,
            replacementUTF16Length: replacementUTF16Length,
            affinity: .start
        )
        let newEnd = transformSelectionBoundary(
            selectionEnd,
            replacing: safeRange,
            replacementUTF16Length: replacementUTF16Length,
            affinity: .end
        )
        let boundedStart = max(0, newStart)
        let boundedEnd = max(boundedStart, newEnd)
        return NSRange(location: boundedStart, length: boundedEnd - boundedStart)
    }

    private enum SelectionBoundaryAffinity {
        case start
        case end
    }

    private func transformSelectionBoundary(
        _ boundary: Int,
        replacing range: NSRange,
        replacementUTF16Length: Int,
        affinity: SelectionBoundaryAffinity
    ) -> Int {
        let replacementStart = range.location
        let replacedEnd = range.location + range.length
        let delta = replacementUTF16Length - range.length

        if boundary < replacementStart {
            return boundary
        }
        if boundary > replacedEnd {
            return boundary + delta
        }

        let offsetInsideReplacement = max(0, boundary - replacementStart)
        let transformedInsideReplacement = replacementStart + min(offsetInsideReplacement, replacementUTF16Length)
        switch affinity {
        case .start:
            return transformedInsideReplacement
        case .end:
            return transformedInsideReplacement
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
