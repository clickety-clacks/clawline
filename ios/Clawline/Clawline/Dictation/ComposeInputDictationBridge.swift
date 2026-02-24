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
        var insertionPoint: Int
        var serverTextLength: Int
        var hasAppliedTranscript: Bool
        var previousServerTranscript: String
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
        let insertionPoint = selectedRange.location == NSNotFound
            ? composeTextView?.attributedText.length ?? 0
            : selectedRange.location
        transcriptStateBySession[sessionKey] = TranscriptState(
            insertionPoint: insertionPoint,
            serverTextLength: 0,
            hasAppliedTranscript: false,
            previousServerTranscript: ""
        )
    }

    func apply(transcript: String, baseSnapshot: ComposeDraftSnapshot, to sessionKey: String) {
        guard let host else { return }
        if applyToComposeTextView(transcript: transcript, sessionKey: sessionKey) {
            return
        }
        let state = transcriptStateBySession[sessionKey]
        let previousUTF16Length = state?.serverTextLength ?? 0
        let replacementText = NSAttributedString(string: transcript, attributes: defaultTextAttributes())
        host.applyComposeDraftDelta(
            baseSnapshot: baseSnapshot,
            previousTranscriptUTF16Length: previousUTF16Length,
            replacementText: replacementText,
            to: sessionKey,
            moveCursorToEnd: true
        )
        transcriptStateBySession[sessionKey] = TranscriptState(
            insertionPoint: baseSnapshot.content.length,
            serverTextLength: transcript.utf16.count,
            hasAppliedTranscript: true,
            previousServerTranscript: transcript
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
            insertionPoint: textView.selectedRange.location == NSNotFound ? textView.attributedText.length : textView.selectedRange.location,
            serverTextLength: 0,
            hasAppliedTranscript: false,
            previousServerTranscript: ""
        )

        if !state.hasAppliedTranscript {
            let fullLength = textView.attributedText.length
            let selectedRange = textView.selectedRange
            let replacementLength = selectedRange.location == NSNotFound ? 0 : selectedRange.length
            let safeLocation = selectedRange.location == NSNotFound
                ? min(max(state.insertionPoint, 0), fullLength)
                : min(max(selectedRange.location, 0), fullLength)
            let safeLength = min(max(replacementLength, 0), max(0, fullLength - safeLocation))
            let replacementRange = NSRange(location: safeLocation, length: safeLength)

            guard let textRange = textRange(in: textView, nsRange: replacementRange) else {
                return false
            }

            textView.replace(textRange, withText: transcript)
            state.insertionPoint = safeLocation
            state.serverTextLength = transcript.utf16.count
            state.hasAppliedTranscript = true
            state.previousServerTranscript = transcript
            transcriptStateBySession[sessionKey] = state
            return true
        }

        let fullLength = textView.attributedText.length
        let regionLocation = min(max(state.insertionPoint, 0), fullLength)
        let regionLength = min(max(state.serverTextLength, 0), max(0, fullLength - regionLocation))
        let serverRegion = NSRange(location: regionLocation, length: regionLength)

        let selection = textView.selectedRange
        if selection.location != NSNotFound,
           selection.length > 0,
           rangesOverlap(selection, serverRegion) {
            let suffix = transcriptSuffix(newTranscript: transcript, previousTranscript: state.previousServerTranscript)
            if let textRange = textRange(in: textView, nsRange: selection) {
                textView.replace(textRange, withText: suffix)
                state.insertionPoint = selection.location
                state.serverTextLength = suffix.utf16.count
                state.previousServerTranscript = transcript
                state.hasAppliedTranscript = true
                transcriptStateBySession[sessionKey] = state
                return true
            }
        }

        let currentRegionText = attributedSubstringString(
            in: textView.attributedText,
            nsRange: serverRegion
        )

        if currentRegionText == state.previousServerTranscript {
            if let textRange = textRange(in: textView, nsRange: serverRegion) {
                textView.replace(textRange, withText: transcript)
                state.serverTextLength = transcript.utf16.count
                state.previousServerTranscript = transcript
                state.hasAppliedTranscript = true
                transcriptStateBySession[sessionKey] = state
                return true
            }
            return false
        }

        let suffix = transcriptSuffix(newTranscript: transcript, previousTranscript: state.previousServerTranscript)
        if !suffix.isEmpty {
            let appendLocation = min(textView.attributedText.length, serverRegion.location + serverRegion.length)
            if let appendRange = textRange(in: textView, nsRange: NSRange(location: appendLocation, length: 0)) {
                textView.replace(appendRange, withText: suffix)
                state.insertionPoint = appendLocation
            }
        } else {
            state.insertionPoint = min(textView.attributedText.length, serverRegion.location + serverRegion.length)
        }
        state.serverTextLength = 0
        state.previousServerTranscript = transcript
        state.hasAppliedTranscript = true
        transcriptStateBySession[sessionKey] = state
        return true
    }

    private func transcriptSuffix(newTranscript: String, previousTranscript: String) -> String {
        guard !previousTranscript.isEmpty else { return newTranscript }
        let common = newTranscript.commonPrefix(with: previousTranscript)
        return String(newTranscript.dropFirst(common.count))
    }

    private func rangesOverlap(_ lhs: NSRange, _ rhs: NSRange) -> Bool {
        NSIntersectionRange(lhs, rhs).length > 0
    }

    private func attributedSubstringString(in attributedText: NSAttributedString, nsRange: NSRange) -> String {
        guard nsRange.location != NSNotFound,
              nsRange.location >= 0,
              nsRange.location <= attributedText.length
        else {
            return ""
        }
        let safeLength = min(max(nsRange.length, 0), attributedText.length - nsRange.location)
        guard safeLength > 0 else { return "" }
        return attributedText.attributedSubstring(from: NSRange(location: nsRange.location, length: safeLength)).string
    }

    private func textRange(in textView: UITextView, nsRange: NSRange) -> UITextRange? {
        guard let start = textView.position(from: textView.beginningOfDocument, offset: nsRange.location),
              let end = textView.position(from: start, offset: nsRange.length) else {
            return nil
        }
        return textView.textRange(from: start, to: end)
    }
}
