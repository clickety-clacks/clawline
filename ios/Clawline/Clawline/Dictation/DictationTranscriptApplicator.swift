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
            replaceText(in: textView, range: safeRange, with: plan.replacementText.string)
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

    private func replaceText(in textView: UITextView, range: NSRange, with text: String) {
        guard let textRange = textRange(in: textView, nsRange: range) else { return }
        if let textView = textView as? PastableTextView {
            textView.beginDictationProgrammaticUpdate()
            defer { textView.endDictationProgrammaticUpdate() }
            textView.replace(textRange, withText: text)
            return
        }
        textView.replace(textRange, withText: text)
    }

    private func textRange(in textView: UITextView, nsRange: NSRange) -> UITextRange? {
        guard let start = textView.position(from: textView.beginningOfDocument, offset: nsRange.location),
              let end = textView.position(from: start, offset: nsRange.length) else {
            return nil
        }
        return textView.textRange(from: start, to: end)
    }
}
