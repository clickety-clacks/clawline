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
        var previousTranscriptUTF16Length: Int
    }

    private weak var host: (any DictationComposeDraftHosting)?
    private var transcriptStateBySession: [String: TranscriptState] = [:]

    init(host: any DictationComposeDraftHosting) {
        self.host = host
    }

    func captureSnapshot(for sessionKey: String) -> ComposeDraftSnapshot {
        host?.captureComposeDraftSnapshot(for: sessionKey) ?? .empty
    }

    func resetTranscriptState(for sessionKey: String) {
        transcriptStateBySession[sessionKey] = TranscriptState(previousTranscriptUTF16Length: 0)
    }

    func apply(transcript: String, baseSnapshot: ComposeDraftSnapshot, to sessionKey: String) {
        guard let host else { return }
        let previousUTF16Length = transcriptStateBySession[sessionKey]?.previousTranscriptUTF16Length ?? 0
        let replacementText = NSAttributedString(string: transcript, attributes: defaultTextAttributes())
        host.applyComposeDraftDelta(
            baseSnapshot: baseSnapshot,
            previousTranscriptUTF16Length: previousUTF16Length,
            replacementText: replacementText,
            to: sessionKey,
            moveCursorToEnd: true
        )
        transcriptStateBySession[sessionKey] = TranscriptState(previousTranscriptUTF16Length: transcript.utf16.count)
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
}
