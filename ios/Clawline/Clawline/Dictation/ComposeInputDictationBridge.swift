//
//  ComposeInputDictationBridge.swift
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

@MainActor
final class ComposeInputDictationBridge {
    private enum ReconciliationMode {
        case correction
        case appendOnly
    }

    private struct TranscriptState {
        var insertionLocation: Int
        var previousTranscriptUTF16Length: Int
        var hasAppliedTranscript: Bool
        var previousServerTranscript: String
        var mode: ReconciliationMode
    }

    private weak var host: (any DictationComposeDraftHosting)?
    private weak var composeTextView: PastableTextView?
    private var transcriptStateBySession: [String: TranscriptState] = [:]

    init(host: any DictationComposeDraftHosting) {
        self.host = host
    }

    func captureSnapshot(for sessionKey: String) -> ComposeDraftSnapshot {
        host?.captureComposeDraftSnapshot(for: sessionKey) ?? .empty
    }

    func setComposeTextView(_ textView: PastableTextView?) {
        composeTextView = textView
    }

    // Kept for compatibility with existing call sites. Selection SSOT is always UITextView.selectedRange.
    func setPreferredSelectionRange(_ selectionRange: NSRange) {
        _ = selectionRange
    }

    func noteUserInteraction(originSessionKey: String?) {
        guard let sessionKey = originSessionKey, !sessionKey.isEmpty else { return }
        guard var state = transcriptStateBySession[sessionKey] else { return }
        state.mode = .appendOnly
        transcriptStateBySession[sessionKey] = state
    }

    func resetTranscriptState(for sessionKey: String) {
        let selectedRange = composeTextView?.selectedRange ?? NSRange(location: NSNotFound, length: 0)
        let insertionLocation = selectedRange.location == NSNotFound
            ? composeTextView?.attributedText.length ?? 0
            : selectedRange.location
        transcriptStateBySession[sessionKey] = TranscriptState(
            insertionLocation: insertionLocation,
            previousTranscriptUTF16Length: 0,
            hasAppliedTranscript: false,
            previousServerTranscript: "",
            mode: .correction
        )
    }

    func apply(transcript: String, baseSnapshot: ComposeDraftSnapshot, originSessionKey: String?) {
        guard let sessionKey = originSessionKey,
              !sessionKey.isEmpty,
              host?.activeSessionKey == sessionKey
        else { return }
        guard let host else { return }

        if applyToComposeTextView(transcript: transcript, sessionKey: sessionKey) {
            return
        }

        let previousUTF16Length = transcriptStateBySession[sessionKey]?.previousTranscriptUTF16Length ?? 0
        let replacementText = NSAttributedString(string: transcript, attributes: defaultTextAttributes())
        host.applyComposeDraftDelta(
            baseSnapshot: baseSnapshot,
            previousTranscriptUTF16Length: previousUTF16Length,
            replacementText: replacementText,
            to: sessionKey,
            moveCursorToEnd: true
        )
        transcriptStateBySession[sessionKey] = TranscriptState(
            insertionLocation: baseSnapshot.content.length,
            previousTranscriptUTF16Length: transcript.utf16.count,
            hasAppliedTranscript: true,
            previousServerTranscript: transcript,
            mode: .correction
        )
    }

    func restore(snapshot: ComposeDraftSnapshot, to sessionKey: String) {
        transcriptStateBySession.removeValue(forKey: sessionKey)
        host?.applyComposeDraftSnapshot(
            snapshot,
            to: sessionKey,
            moveCursorToEnd: false,
            announceEditorReset: true
        )
    }

    private func defaultTextAttributes() -> [NSAttributedString.Key: Any] {
        [
            .font: UIFont.preferredFont(forTextStyle: .body),
            .foregroundColor: UIColor.label
        ]
    }

    private func applyToComposeTextView(transcript: String, sessionKey: String) -> Bool {
        guard let textView = composeTextView else { return false }
        var state = transcriptStateBySession[sessionKey] ?? TranscriptState(
            insertionLocation: textView.selectedRange.location == NSNotFound ? textView.attributedText.length : textView.selectedRange.location,
            previousTranscriptUTF16Length: 0,
            hasAppliedTranscript: false,
            previousServerTranscript: "",
            mode: .correction
        )

        if !state.hasAppliedTranscript {
            let selectedRange = textView.selectedRange
            let replacementRange = safeReplacementRange(
                selectedRange: selectedRange,
                textLength: textView.attributedText.length,
                fallbackLocation: state.insertionLocation
            )
            replaceText(in: textView, range: replacementRange, with: transcript)
            state.insertionLocation = replacementRange.location
            state.previousTranscriptUTF16Length = transcript.utf16.count
            state.hasAppliedTranscript = true
            state.previousServerTranscript = transcript
            state.mode = .correction
            transcriptStateBySession[sessionKey] = state
            return true
        }

        switch state.mode {
        case .appendOnly:
            // In append-only mode, accept only monotonic append updates for this cycle.
            guard transcript.hasPrefix(state.previousServerTranscript) else {
                transcriptStateBySession[sessionKey] = state
                return true
            }
            let suffix = String(transcript.dropFirst(state.previousServerTranscript.count))
            if !suffix.isEmpty {
                appendText(textView, suffix)
                state.previousServerTranscript = transcript
                state.previousTranscriptUTF16Length = transcript.utf16.count
                // Immediate return to correction mode after one successful append.
                state.mode = .correction
            }
            transcriptStateBySession[sessionKey] = state
            return true

        case .correction:
            // Correction mode: apply server revisions against the dictated segment tail.
            let previous = state.previousServerTranscript
            let common = transcript.commonPrefix(with: previous)
            let commonUTF16 = common.utf16.count
            let previousUTF16 = previous.utf16.count
            let newTail = String(transcript.dropFirst(common.count))

            let replaceStart = min(
                textView.attributedText.length,
                max(0, state.insertionLocation + commonUTF16)
            )
            let replaceLength = max(0, previousUTF16 - commonUTF16)
            let safeLength = min(replaceLength, max(0, textView.attributedText.length - replaceStart))
            let replaceRange = NSRange(location: replaceStart, length: safeLength)
            replaceText(in: textView, range: replaceRange, with: newTail)

            state.previousServerTranscript = transcript
            state.previousTranscriptUTF16Length = transcript.utf16.count
            transcriptStateBySession[sessionKey] = state
            return true
        }
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
            textView.dictationIgnoreNextSelectionInteraction = true
            textView.dictationProgrammaticUpdateInFlight = true
            defer { textView.dictationProgrammaticUpdateInFlight = false }
            textView.replace(textRange, withText: text)
            return
        }
        textView.replace(textRange, withText: text)
    }

    private func appendText(_ textView: UITextView, _ text: String) {
        guard !text.isEmpty else { return }
        if let textView = textView as? PastableTextView {
            textView.dictationIgnoreNextSelectionInteraction = true
            textView.dictationProgrammaticUpdateInFlight = true
            defer { textView.dictationProgrammaticUpdateInFlight = false }
            textView.insertText(text)
            return
        }
        textView.insertText(text)
    }

    private func textRange(in textView: UITextView, nsRange: NSRange) -> UITextRange? {
        guard let start = textView.position(from: textView.beginningOfDocument, offset: nsRange.location),
              let end = textView.position(from: start, offset: nsRange.length) else {
            return nil
        }
        return textView.textRange(from: start, to: end)
    }
}
