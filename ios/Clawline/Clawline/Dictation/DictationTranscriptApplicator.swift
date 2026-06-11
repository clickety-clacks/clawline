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

enum DictationTextApplicationMode: Equatable {
    case replaceRange
    case restoreBaseAndAppendReplacement
}

@MainActor
protocol DictationComposeDraftHosting: AnyObject {
    var activeSessionKey: String { get }

    func isComposeDraftSessionCurrent(_ sessionKey: String) -> Bool
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

@MainActor
protocol DictationTextTargetIdentifying: AnyObject {
    var dictationTargetSessionKey: String { get }
}

struct DictationTextApplicationPlan {
    let sessionKey: String
    let baseSnapshot: ComposeDraftSnapshot
    let replacementRange: NSRange
    let fallbackReplacementRange: NSRange
    let fallbackLocation: Int
    let replacementText: NSAttributedString
    let selectionPolicy: DictationSelectionPolicy
    let applicationMode: DictationTextApplicationMode
    let suppressReentrantFeedback: Bool

    init(
        sessionKey: String,
        baseSnapshot: ComposeDraftSnapshot,
        replacementRange: NSRange,
        fallbackReplacementRange: NSRange? = nil,
        fallbackLocation: Int,
        replacementText: NSAttributedString,
        selectionPolicy: DictationSelectionPolicy,
        applicationMode: DictationTextApplicationMode = .replaceRange,
        suppressReentrantFeedback: Bool
    ) {
        self.sessionKey = sessionKey
        self.baseSnapshot = baseSnapshot
        self.replacementRange = replacementRange
        self.fallbackReplacementRange = fallbackReplacementRange ?? replacementRange
        self.fallbackLocation = fallbackLocation
        self.replacementText = replacementText
        self.selectionPolicy = selectionPolicy
        self.applicationMode = applicationMode
        self.suppressReentrantFeedback = suppressReentrantFeedback
    }
}

@MainActor
final class DictationTranscriptApplicator {
    private weak var host: (any DictationComposeDraftHosting)?
    private weak var composeTextView: UITextView?
    private var composeTextViewTargetSessionKey: String?
    private var replayPlanProvider: (@MainActor () -> DictationTextApplicationPlan?)?

    init(host: any DictationComposeDraftHosting) {
        self.host = host
    }

    var boundComposeTextView: UITextView? {
        composeTextView
    }

    func setReplayPlanProvider(_ provider: @escaping @MainActor () -> DictationTextApplicationPlan?) {
        replayPlanProvider = provider
    }

    func captureSnapshot(for sessionKey: String) -> ComposeDraftSnapshot {
        if let targetTextView = composeTextView as? DictationTextTargetIdentifying,
           !targetTextView.dictationTargetSessionKey.isEmpty,
           targetTextView.dictationTargetSessionKey == sessionKey {
            let hostSnapshot = host?.captureComposeDraftSnapshot(for: sessionKey) ?? .empty
            return ComposeDraftSnapshot(
                content: composeTextView?.attributedText ?? NSAttributedString(string: ""),
                attachments: hostSnapshot.attachments
            )
        }
        if composeTextView != nil,
           host?.isComposeDraftSessionCurrent(sessionKey) == true {
            let hostSnapshot = host?.captureComposeDraftSnapshot(for: sessionKey) ?? .empty
            guard boundComposeTextViewContentMatchesHostSnapshot(for: sessionKey) else {
                return hostSnapshot
            }
            return ComposeDraftSnapshot(
                content: composeTextView?.attributedText ?? NSAttributedString(string: ""),
                attachments: hostSnapshot.attachments
            )
        }
        return host?.captureComposeDraftSnapshot(for: sessionKey) ?? .empty
    }

    func captureHostSnapshot(for sessionKey: String) -> ComposeDraftSnapshot {
        host?.captureComposeDraftSnapshot(for: sessionKey) ?? .empty
    }

    func captureSelectionRange(for sessionKey: String) -> NSRange? {
        guard let textView = boundTextView(for: sessionKey) else { return nil }
        if !(textView is DictationTextTargetIdentifying) {
            guard boundComposeTextViewContentMatchesHostSnapshot(for: sessionKey) else { return nil }
        }
        let selectionRange = textView.selectedRange
        guard selectionRange.location != NSNotFound else { return nil }
        return safeReplacementRange(
            selectedRange: selectionRange,
            textLength: textView.attributedText.length,
            fallbackLocation: textView.attributedText.length
        )
    }

    func boundComposeTextViewContentMatchesHostSnapshot(for sessionKey: String) -> Bool {
        guard let textView = boundTextView(for: sessionKey) else { return false }
        guard !(textView is DictationTextTargetIdentifying) else { return true }
        let hostSnapshot = host?.captureComposeDraftSnapshot(for: sessionKey) ?? .empty
        return textView.attributedText.isEqual(to: hostSnapshot.content)
    }

    func setComposeTextView(_ textView: UITextView?) {
        let previousTextView = composeTextView
        let previousSelection = previousTextView?.selectedRange
        let previousTargetSessionKey = composeTextViewTargetSessionKey
        composeTextView = textView
        composeTextViewTargetSessionKey = (textView as? DictationTextTargetIdentifying)?.dictationTargetSessionKey
        guard previousTextView !== textView || previousTargetSessionKey != composeTextViewTargetSessionKey else {
            return
        }
        guard let textView else { return }
        replayCurrentPlanIfAvailable()
        if let previousSelection,
           previousSelection.location != NSNotFound {
            textView.selectedRange = safeReplacementRange(
                selectedRange: previousSelection,
                textLength: textView.attributedText.length,
                fallbackLocation: textView.attributedText.length
            )
        }
    }

    func unbindUntargetedComposeTextView() {
        guard composeTextView != nil else { return }
        guard !(composeTextView is DictationTextTargetIdentifying) else { return }
        composeTextView = nil
        composeTextViewTargetSessionKey = nil
    }

    func replayCurrentPlanIfAvailable() {
        guard let replayPlan = replayPlanProvider?() else { return }
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
        guard host?.isComposeDraftSessionCurrent(plan.sessionKey) == true || boundTextViewTargets(plan.sessionKey) else {
            return
        }

        if plan.applicationMode == .restoreBaseAndAppendReplacement {
            applyFallbackSnapshot(from: plan)
            return
        }

        if let textView = boundTextView(for: plan.sessionKey) {
            let safeRange = safeReplacementRange(
                selectedRange: plan.replacementRange,
                textLength: textView.attributedText.length,
                fallbackLocation: plan.fallbackLocation
            )
            replaceText(
                in: textView,
                range: safeRange,
                with: plan.replacementText.string,
                selectionPolicy: plan.selectionPolicy,
                suppressReentrantFeedback: plan.suppressReentrantFeedback
            )
            return
        }

        guard let host else { return }
        let currentSnapshot = host.captureComposeDraftSnapshot(for: plan.sessionKey)
        let current = NSMutableAttributedString(attributedString: currentSnapshot.content)
        if !isValidReplacementRange(plan.replacementRange, textLength: current.length) {
            applyFallbackSnapshot(from: plan)
            return
        }
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

        applyFallbackSnapshot(from: plan)
    }

    func restore(snapshot: ComposeDraftSnapshot, to sessionKey: String) {
        host?.applyComposeDraftSnapshot(
            snapshot,
            to: sessionKey,
            moveCursorToEnd: false,
            announceEditorReset: true
        )
        guard host?.isComposeDraftSessionCurrent(sessionKey) == true || boundTextViewTargets(sessionKey),
              let composeTextView = boundTextView(for: sessionKey) else { return }
        replaceSnapshot(snapshot, in: composeTextView, suppressReentrantFeedback: true)
    }

    private func boundTextViewTargets(_ sessionKey: String) -> Bool {
        guard let targetSessionKey = (composeTextView as? DictationTextTargetIdentifying)?
            .dictationTargetSessionKey,
              !targetSessionKey.isEmpty else {
            return false
        }
        return targetSessionKey == sessionKey
    }

    private func boundTextView(for sessionKey: String) -> UITextView? {
        guard let composeTextView else { return nil }
        if let targetTextView = composeTextView as? DictationTextTargetIdentifying {
            guard !targetTextView.dictationTargetSessionKey.isEmpty else {
                return host?.isComposeDraftSessionCurrent(sessionKey) == true ? composeTextView : nil
            }
            return targetTextView.dictationTargetSessionKey == sessionKey ? composeTextView : nil
        }
        return host?.isComposeDraftSessionCurrent(sessionKey) == true ? composeTextView : nil
    }

    private func safeReplacementRange(selectedRange: NSRange, textLength: Int, fallbackLocation: Int) -> NSRange {
        let replacementLength = selectedRange.location == NSNotFound ? 0 : selectedRange.length
        let location = selectedRange.location == NSNotFound
            ? min(max(fallbackLocation, 0), textLength)
            : min(max(selectedRange.location, 0), textLength)
        let length = min(max(replacementLength, 0), max(0, textLength - location))
        return NSRange(location: location, length: length)
    }

    private func isValidReplacementRange(_ range: NSRange, textLength: Int) -> Bool {
        guard range.location != NSNotFound,
              range.location >= 0,
              range.length >= 0 else {
            return false
        }
        return range.location + range.length <= textLength
    }

    private func applyFallbackSnapshot(from plan: DictationTextApplicationPlan) {
        guard let host else { return }
        let fallback = NSMutableAttributedString(attributedString: plan.baseSnapshot.content)
        let replacementRange: NSRange
        if isValidReplacementRange(plan.fallbackReplacementRange, textLength: fallback.length) {
            replacementRange = plan.fallbackReplacementRange
        } else {
            replacementRange = NSRange(
                location: min(max(plan.fallbackLocation, 0), fallback.length),
                length: 0
            )
        }
        fallback.replaceCharacters(in: replacementRange, with: plan.replacementText)
        let snapshot = ComposeDraftSnapshot(content: fallback, attachments: plan.baseSnapshot.attachments)
        host.applyComposeDraftSnapshot(
            snapshot,
            to: plan.sessionKey,
            moveCursorToEnd: plan.selectionPolicy == .followTranscriptEndWhenSelectionAlreadyAtEnd,
            announceEditorReset: false
        )
        if let composeTextView = boundTextView(for: plan.sessionKey) {
            replaceSnapshot(snapshot, in: composeTextView, suppressReentrantFeedback: plan.suppressReentrantFeedback)
        }
    }

    private func replaceText(
        in textView: UITextView,
        range: NSRange,
        with text: String,
        selectionPolicy: DictationSelectionPolicy,
        suppressReentrantFeedback: Bool
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
            if suppressReentrantFeedback {
                pastable.dictationProgrammaticEditInFlight = true
                pastable.expectDictationProgrammaticSelectionFeedback(selectionAfterReplacement)
            }
            textView.replace(textRange, withText: text)
            if textView.selectedRange != selectionAfterReplacement {
                textView.selectedRange = selectionAfterReplacement
            }
            if suppressReentrantFeedback {
                pastable.dictationProgrammaticEditInFlight = false
            }
            return
        }
        textView.replace(textRange, withText: text)
        if textView.selectedRange != selectionAfterReplacement {
            textView.selectedRange = selectionAfterReplacement
        }
    }

    private func replaceSnapshot(
        _ snapshot: ComposeDraftSnapshot,
        in textView: UITextView,
        suppressReentrantFeedback: Bool
    ) {
        let location = snapshot.content.length
        let selection = NSRange(location: location, length: 0)
        if let pastable = textView as? PastableTextView {
            if suppressReentrantFeedback {
                pastable.dictationProgrammaticEditInFlight = true
                pastable.expectDictationProgrammaticSelectionFeedback(selection)
            }
            textView.attributedText = snapshot.content
        } else {
            textView.attributedText = snapshot.content
        }
        if textView.selectedRange != selection {
            textView.selectedRange = selection
        }
        if let pastable = textView as? PastableTextView {
            if suppressReentrantFeedback {
                pastable.dictationProgrammaticEditInFlight = false
            }
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

        if safeSelection.length > 0,
           safeSelection == safeRange {
            return NSRange(location: replacementEnd, length: 0)
        }

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
