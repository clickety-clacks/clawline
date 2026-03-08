import Testing
import UIKit
@testable import Clawline

@MainActor
struct ComposeInputDictationBridgeTests {
    @Test("Dictation replaces the current selection instead of appending")
    func dictationReplacesCurrentSelection() {
        let host = BridgeHost()
        let bridge = ComposeInputDictationBridge(host: host)
        let textView = PastableTextView()
        textView.attributedText = NSAttributedString(string: "hello world")
        textView.selectedRange = NSRange(location: 6, length: 5)
        bridge.setComposeTextView(textView)

        let sessionKey = "agent:main:test:main"
        let snapshot = ComposeDraftSnapshot(
            content: NSAttributedString(string: "hello world"),
            attachments: [:]
        )

        bridge.setPreferredSelectionRange(textView.selectedRange, for: sessionKey)
        bridge.resetTranscriptState(for: sessionKey)
        bridge.applySegmentUpdate(
            DictationSegmentUpdate(
                provisionalText: "mars",
                committedSegments: [],
                finished: false,
                sawEndpoint: false,
                hadAnyTokens: true
            ),
            baseSnapshot: snapshot,
            originSessionKey: sessionKey
        )

        #expect(textView.attributedText.string == "hello mars")
    }

    @Test("Dictation inserts at the coordinator selection even if UIKit collapses live selection")
    func dictationUsesCoordinatorSelectionWhenLiveSelectionCollapses() {
        let host = BridgeHost()
        let bridge = ComposeInputDictationBridge(host: host)
        let textView = PastableTextView()
        textView.attributedText = NSAttributedString(string: "hello world")
        textView.selectedRange = NSRange(location: 11, length: 0)
        bridge.setComposeTextView(textView)

        let sessionKey = "agent:main:test:main"
        let snapshot = ComposeDraftSnapshot(
            content: NSAttributedString(string: "hello world"),
            attachments: [:]
        )

        bridge.setPreferredSelectionRange(NSRange(location: 6, length: 0), for: sessionKey)
        bridge.resetTranscriptState(for: sessionKey)
        bridge.applySegmentUpdate(
            DictationSegmentUpdate(
                provisionalText: "beautiful ",
                committedSegments: [],
                finished: false,
                sawEndpoint: false,
                hadAnyTokens: true
            ),
            baseSnapshot: snapshot,
            originSessionKey: sessionKey
        )

        #expect(textView.attributedText.string == "hello beautiful world")
    }
}

@MainActor
private final class BridgeHost: DictationComposeDraftHosting {
    var activeSessionKey: String = "agent:main:test:main"

    func captureComposeDraftSnapshot(for sessionKey: String) -> ComposeDraftSnapshot {
        let _ = sessionKey
        return .empty
    }

    func applyComposeDraftDelta(
        baseSnapshot: ComposeDraftSnapshot,
        previousTranscriptUTF16Length: Int,
        replacementText: NSAttributedString,
        to sessionKey: String,
        moveCursorToEnd: Bool
    ) {
        let _ = baseSnapshot
        let _ = previousTranscriptUTF16Length
        let _ = replacementText
        let _ = sessionKey
        let _ = moveCursorToEnd
    }

    func applyComposeDraftSnapshot(
        _ snapshot: ComposeDraftSnapshot,
        to sessionKey: String,
        moveCursorToEnd: Bool,
        announceEditorReset: Bool
    ) {
        let _ = snapshot
        let _ = sessionKey
        let _ = moveCursorToEnd
        let _ = announceEditorReset
    }
}
