import Foundation
import Testing
import UIKit
@testable import Clawline

@MainActor
struct ComposeInputDictationBridgeModeSwitchTests {
    @Test("Correction mode applies server revisions")
    func correctionModeAppliesServerRevisions() {
        let host = BridgeModeTestHost()
        let bridge = ComposeInputDictationBridge(host: host)
        let textView = PastableTextView()

        host.setText("seed ", for: host.activeSessionKey)
        textView.attributedText = NSAttributedString(string: "seed ")
        textView.selectedRange = NSRange(location: textView.attributedText.length, length: 0)

        bridge.setComposeTextView(textView)
        bridge.resetTranscriptState(for: host.activeSessionKey)

        bridge.apply(transcript: "hello worl", baseSnapshot: .empty, originSessionKey: host.activeSessionKey)
        #expect(textView.attributedText.string == "seed hello worl")

        bridge.apply(transcript: "hello world", baseSnapshot: .empty, originSessionKey: host.activeSessionKey)
        #expect(textView.attributedText.string == "seed hello world")

        bridge.apply(transcript: "hello brave world", baseSnapshot: .empty, originSessionKey: host.activeSessionKey)
        #expect(textView.attributedText.string == "seed hello brave world")
    }

    @Test("User interaction flips to append-only for one successful monotonic append")
    func userInteractionFlipToAppendOnlyCycle() {
        let host = BridgeModeTestHost()
        let bridge = ComposeInputDictationBridge(host: host)
        let textView = PastableTextView()

        host.setText("seed ", for: host.activeSessionKey)
        textView.attributedText = NSAttributedString(string: "seed ")
        textView.selectedRange = NSRange(location: textView.attributedText.length, length: 0)

        bridge.setComposeTextView(textView)
        bridge.resetTranscriptState(for: host.activeSessionKey)

        bridge.apply(transcript: "hello world", baseSnapshot: .empty, originSessionKey: host.activeSessionKey)
        #expect(textView.attributedText.string == "seed hello world")

        // User directly manipulates the editor during active dictation.
        bridge.noteUserInteraction(originSessionKey: host.activeSessionKey)

        // Non-monotonic revision is rejected while in append-only mode.
        bridge.apply(transcript: "hello brave world", baseSnapshot: .empty, originSessionKey: host.activeSessionKey)
        #expect(textView.attributedText.string == "seed hello world")

        textView.selectedRange = NSRange(location: textView.attributedText.length, length: 0)

        // Monotonic append succeeds and immediately re-enables correction mode.
        bridge.apply(transcript: "hello world!", baseSnapshot: .empty, originSessionKey: host.activeSessionKey)
        #expect(textView.attributedText.string == "seed hello world!")

        // Correction mode should be active again, so non-monotonic revision applies.
        bridge.apply(transcript: "hello wonderful world!", baseSnapshot: .empty, originSessionKey: host.activeSessionKey)
        #expect(textView.attributedText.string == "seed hello wonderful world!")
    }
}

@MainActor
private final class BridgeModeTestHost: DictationComposeDraftHosting {
    var activeSessionKey: String = "agent:main:test:bridge"
    private var drafts: [String: ComposeDraftSnapshot] = ["agent:main:test:bridge": .empty]

    func captureComposeDraftSnapshot(for sessionKey: String) -> ComposeDraftSnapshot {
        drafts[sessionKey] ?? .empty
    }

    func applyComposeDraftDelta(
        baseSnapshot: ComposeDraftSnapshot,
        previousTranscriptUTF16Length: Int,
        replacementText: NSAttributedString,
        to sessionKey: String,
        moveCursorToEnd: Bool
    ) {
        let _ = previousTranscriptUTF16Length
        let _ = moveCursorToEnd
        let mutable = NSMutableAttributedString(attributedString: baseSnapshot.content)
        mutable.append(replacementText)
        drafts[sessionKey] = ComposeDraftSnapshot(content: mutable, attachments: baseSnapshot.attachments)
    }

    func applyComposeDraftSnapshot(
        _ snapshot: ComposeDraftSnapshot,
        to sessionKey: String,
        moveCursorToEnd: Bool,
        announceEditorReset: Bool
    ) {
        let _ = moveCursorToEnd
        let _ = announceEditorReset
        drafts[sessionKey] = snapshot
    }

    func setText(_ text: String, for sessionKey: String) {
        drafts[sessionKey] = ComposeDraftSnapshot(content: NSAttributedString(string: text), attachments: [:])
    }
}
