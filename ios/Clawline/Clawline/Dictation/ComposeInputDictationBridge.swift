//
//  ComposeInputDictationBridge.swift
//  Clawline
//
//  Created by Codex on 2/13/26.
//

import Foundation
import UIKit
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
        var dictationStartUTF16: Int
        var committedLenUTF16: Int
        var provisionalText: String
        var suppressedUntilNextEndpoint: Bool
        var committedText: String

        var provisionalLenUTF16: Int {
            provisionalText.utf16.count
        }

        var previousTranscriptUTF16Length: Int {
            committedLenUTF16 + provisionalLenUTF16
        }
    }

    private weak var host: (any DictationComposeDraftHosting)?
    private weak var composeTextView: PastableTextView?
    private var transcriptStateBySession: [String: TranscriptState] = [:]
    private var preferredSelectionRangeBySession: [String: NSRange] = [:]

    init(host: any DictationComposeDraftHosting) {
        self.host = host
    }

    func captureSnapshot(for sessionKey: String) -> ComposeDraftSnapshot {
        host?.captureComposeDraftSnapshot(for: sessionKey) ?? .empty
    }

    func setComposeTextView(_ textView: PastableTextView?) {
        composeTextView = textView
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

    // Prefer the coordinator-captured selection for dictation start to avoid transient
    // UIKit selection collapse when gesture/tap focus changes right before activation.
    func setPreferredSelectionRange(_ selectionRange: NSRange, for sessionKey: String?) {
        guard let sessionKey, !sessionKey.isEmpty else { return }
        if selectionRange.location != NSNotFound {
            preferredSelectionRangeBySession[sessionKey] = selectionRange
            return
        }
        if let liveSelectionRange = composeTextView?.selectedRange {
            preferredSelectionRangeBySession[sessionKey] = liveSelectionRange
        }
    }

    func noteUserEdit(
        editedRangeUTF16: NSRange,
        replacementUTF16Length: Int,
        originSessionKey: String?
    ) {
        guard let sessionKey = originSessionKey,
              !sessionKey.isEmpty,
              host?.activeSessionKey == sessionKey
        else { return }
        guard var state = transcriptStateBySession[sessionKey] else { return }

        let provisionalRange = NSRange(
            location: state.dictationStartUTF16 + state.committedLenUTF16,
            length: state.provisionalLenUTF16
        )
        if rangesIntersect(editedRangeUTF16, provisionalRange) {
            state.committedText += state.provisionalText
            state.committedLenUTF16 += state.provisionalLenUTF16
            state.provisionalText = ""
            state.suppressedUntilNextEndpoint = true
        }

        let committedStart = state.dictationStartUTF16
        let committedEnd = committedStart + state.committedLenUTF16
        let newCommittedStart = transformBoundary(
            committedStart,
            editedRange: editedRangeUTF16,
            replacementUTF16Length: replacementUTF16Length,
            affinity: .start
        )
        let newCommittedEnd = transformBoundary(
            committedEnd,
            editedRange: editedRangeUTF16,
            replacementUTF16Length: replacementUTF16Length,
            affinity: .end
        )

        state.dictationStartUTF16 = max(0, newCommittedStart)
        state.committedLenUTF16 = max(0, newCommittedEnd - newCommittedStart)
        transcriptStateBySession[sessionKey] = state
    }

    func resetTranscriptState(for sessionKey: String) {
        let selectedRange = preferredSelectionRangeBySession[sessionKey]
            ?? composeTextView?.selectedRange
            ?? NSRange(location: NSNotFound, length: 0)
        let textLength = composeTextView?.attributedText.length ?? 0
        let clampedSelectionRange: NSRange = {
            guard selectedRange.location != NSNotFound else {
                return NSRange(location: textLength, length: 0)
            }
            let location = min(max(selectedRange.location, 0), textLength)
            let length = min(max(selectedRange.length, 0), max(0, textLength - location))
            return NSRange(location: location, length: length)
        }()
        let initialProvisionalText: String = {
            guard clampedSelectionRange.length > 0,
                  let text = composeTextView?.attributedText.string else {
                return ""
            }
            return substring(text: text, utf16Range: clampedSelectionRange) ?? ""
        }()
        transcriptStateBySession[sessionKey] = TranscriptState(
            dictationStartUTF16: clampedSelectionRange.location,
            committedLenUTF16: 0,
            provisionalText: initialProvisionalText,
            suppressedUntilNextEndpoint: false,
            committedText: ""
        )
        preferredSelectionRangeBySession.removeValue(forKey: sessionKey)
    }

    func applySegmentUpdate(
        _ update: DictationSegmentUpdate,
        baseSnapshot: ComposeDraftSnapshot,
        originSessionKey: String?
    ) {
        guard let sessionKey = originSessionKey,
              !sessionKey.isEmpty,
              host?.activeSessionKey == sessionKey
        else { return }
        guard let host else { return }
        var state = transcriptStateBySession[sessionKey] ?? TranscriptState(
            dictationStartUTF16: baseSnapshot.content.length,
            committedLenUTF16: 0,
            provisionalText: "",
            suppressedUntilNextEndpoint: false,
            committedText: ""
        )
        let previousTranscriptUTF16Length = state.previousTranscriptUTF16Length

        if let textView = composeTextView {
            syncCommittedTextFromComposeTextView(textView: textView, state: &state)
            applySegmentUpdateToComposeTextView(update, textView: textView, state: &state)
            transcriptStateBySession[sessionKey] = state
            return
        }

        applySegmentUpdateToState(update, state: &state) { _, _, _ in }
        let replacementText = NSAttributedString(
            string: state.committedText + state.provisionalText,
            attributes: defaultTextAttributes()
        )
        host.applyComposeDraftDelta(
            baseSnapshot: baseSnapshot,
            previousTranscriptUTF16Length: previousTranscriptUTF16Length,
            replacementText: replacementText,
            to: sessionKey,
            moveCursorToEnd: true
        )
        transcriptStateBySession[sessionKey] = state
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

    private func applySegmentUpdateToComposeTextView(
        _ update: DictationSegmentUpdate,
        textView: UITextView,
        state: inout TranscriptState
    ) {
        applySegmentUpdateToState(update, state: &state) { replacement, provisionalRange, fallbackLocation in
            let safeRange = safeReplacementRange(
                selectedRange: provisionalRange,
                textLength: textView.attributedText.length,
                fallbackLocation: fallbackLocation
            )
            replaceText(in: textView, range: safeRange, with: replacement)
        }
    }

    private func applySegmentUpdateToState(
        _ update: DictationSegmentUpdate,
        state: inout TranscriptState,
        replaceProvisionalRange: (_ replacement: String, _ provisionalRange: NSRange, _ fallbackLocation: Int) -> Void
    ) {
        var shouldSkipFirstEndpointCommit = state.suppressedUntilNextEndpoint
        var processedAnyEndpoint = false

        for segment in update.committedSegments {
            processedAnyEndpoint = true
            if shouldSkipFirstEndpointCommit {
                shouldSkipFirstEndpointCommit = false
                state.suppressedUntilNextEndpoint = false
                state.provisionalText = ""
                continue
            }

            let fallbackLocation = state.dictationStartUTF16 + state.committedLenUTF16
            let provisionalRange = NSRange(location: fallbackLocation, length: state.provisionalLenUTF16)
            replaceProvisionalRange(segment, provisionalRange, fallbackLocation)
            state.committedText += segment
            state.committedLenUTF16 += segment.utf16.count
            state.provisionalText = ""
        }

        if state.suppressedUntilNextEndpoint && update.sawEndpoint && !processedAnyEndpoint {
            state.suppressedUntilNextEndpoint = false
            shouldSkipFirstEndpointCommit = false
            state.provisionalText = ""
        } else {
            state.suppressedUntilNextEndpoint = shouldSkipFirstEndpointCommit
        }

        if state.suppressedUntilNextEndpoint {
            // Ignore provisional revisions while suppressed.
        } else {
            let fallbackLocation = state.dictationStartUTF16 + state.committedLenUTF16
            let provisionalRange = NSRange(location: fallbackLocation, length: state.provisionalLenUTF16)
            replaceProvisionalRange(update.provisionalText, provisionalRange, fallbackLocation)
            state.provisionalText = update.provisionalText
        }

        if update.finished {
            if state.suppressedUntilNextEndpoint {
                state.suppressedUntilNextEndpoint = false
                state.provisionalText = ""
            } else if !state.provisionalText.isEmpty {
                state.committedText += state.provisionalText
                state.committedLenUTF16 += state.provisionalLenUTF16
                state.provisionalText = ""
            }
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

    private func textRange(in textView: UITextView, nsRange: NSRange) -> UITextRange? {
        guard let start = textView.position(from: textView.beginningOfDocument, offset: nsRange.location),
              let end = textView.position(from: start, offset: nsRange.length) else {
            return nil
        }
        return textView.textRange(from: start, to: end)
    }

    private func syncCommittedTextFromComposeTextView(textView: UITextView, state: inout TranscriptState) {
        let committedRange = NSRange(location: state.dictationStartUTF16, length: state.committedLenUTF16)
        guard let committedSubstring = substring(
            text: textView.attributedText.string,
            utf16Range: committedRange
        ) else { return }
        state.committedText = committedSubstring
    }

    private func substring(text: String, utf16Range: NSRange) -> String? {
        let nsString = text as NSString
        guard utf16Range.location >= 0,
              utf16Range.length >= 0,
              utf16Range.location + utf16Range.length <= nsString.length else {
            return nil
        }
        return nsString.substring(with: utf16Range)
    }

    private enum BoundaryAffinity {
        case start
        case end
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

    private func rangesIntersect(_ a: NSRange, _ b: NSRange) -> Bool {
        if a.length == 0 {
            let point = a.location
            return point >= b.location && point <= b.location + b.length
        }
        return NSIntersectionRange(a, b).length > 0
    }
}
