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
    private struct TranscriptState {
        var insertionLocation: Int
        var initialReplacementUTF16Length: Int
        var previousTranscriptUTF16Length: Int
        var hasAppliedTranscript: Bool
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

    func resetTranscriptState(for sessionKey: String) {
        let selectedRange = composeTextView?.selectedRange ?? NSRange(location: NSNotFound, length: 0)
        let insertionLocation = selectedRange.location == NSNotFound
            ? composeTextView?.attributedText.length ?? 0
            : selectedRange.location
        let initialReplacementLength = selectedRange.location == NSNotFound ? 0 : selectedRange.length
        transcriptStateBySession[sessionKey] = TranscriptState(
            insertionLocation: insertionLocation,
            initialReplacementUTF16Length: initialReplacementLength,
            previousTranscriptUTF16Length: 0,
            hasAppliedTranscript: false
        )
    }

    func apply(transcript: String, baseSnapshot: ComposeDraftSnapshot, to sessionKey: String) {
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
            initialReplacementUTF16Length: 0,
            previousTranscriptUTF16Length: transcript.utf16.count,
            hasAppliedTranscript: true
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
            initialReplacementUTF16Length: textView.selectedRange.location == NSNotFound ? 0 : textView.selectedRange.length,
            previousTranscriptUTF16Length: 0,
            hasAppliedTranscript: false
        )

        let replacementLength = state.hasAppliedTranscript
            ? state.previousTranscriptUTF16Length
            : state.initialReplacementUTF16Length
        let fullLength = textView.attributedText.length
        let safeLocation = min(max(state.insertionLocation, 0), fullLength)
        let safeLength = min(max(replacementLength, 0), max(0, fullLength - safeLocation))
        let replacementRange = NSRange(location: safeLocation, length: safeLength)

        guard let textRange = textRange(in: textView, nsRange: replacementRange) else {
            return false
        }

        textView.replace(textRange, withText: transcript)
        state.insertionLocation = safeLocation
        state.previousTranscriptUTF16Length = transcript.utf16.count
        state.hasAppliedTranscript = true
        transcriptStateBySession[sessionKey] = state
        return true
    }

    private func textRange(in textView: UITextView, nsRange: NSRange) -> UITextRange? {
        guard let start = textView.position(from: textView.beginningOfDocument, offset: nsRange.location),
              let end = textView.position(from: start, offset: nsRange.length) else {
            return nil
        }
        return textView.textRange(from: start, to: end)
    }
}
