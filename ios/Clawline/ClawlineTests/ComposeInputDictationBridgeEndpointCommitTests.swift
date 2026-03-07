import Foundation
import Testing
import UIKit
@testable import Clawline

@MainActor
struct ComposeInputDictationBridgeEndpointCommitTests {
    @Test("Provisional updates rewrite only provisional range")
    func provisionalUpdatesReplaceOnlyProvisionalRange() {
        let host = BridgeEndpointTestHost()
        let bridge = ComposeInputDictationBridge(host: host)
        let textView = PastableTextView()

        seed(textView: textView, with: "seed ", selectedRange: NSRange(location: 5, length: 0))
        bridge.setComposeTextView(textView)
        bridge.resetTranscriptState(for: host.activeSessionKey)

        apply(
            bridge: bridge,
            update: update(provisional: "hel"),
            host: host
        )
        #expect(textView.attributedText.string == "seed hel")

        apply(
            bridge: bridge,
            update: update(provisional: "hello"),
            host: host
        )
        #expect(textView.attributedText.string == "seed hello")

        apply(
            bridge: bridge,
            update: update(provisional: "hello there"),
            host: host
        )
        #expect(textView.attributedText.string == "seed hello there")
    }

    @Test("Endpoint commits freeze previously committed transcript boundary")
    func endpointCommitFreezesPreviouslyCommittedText() {
        let host = BridgeEndpointTestHost()
        let bridge = ComposeInputDictationBridge(host: host)
        let textView = PastableTextView()

        seed(textView: textView, with: "seed ", selectedRange: NSRange(location: 5, length: 0))
        bridge.setComposeTextView(textView)
        bridge.resetTranscriptState(for: host.activeSessionKey)

        apply(bridge: bridge, update: update(provisional: "hello wor"), host: host)
        apply(
            bridge: bridge,
            update: update(committed: ["hello world"], sawEndpoint: true),
            host: host
        )
        #expect(textView.attributedText.string == "seed hello world")

        apply(
            bridge: bridge,
            update: update(provisional: " from provisional"),
            host: host
        )
        #expect(textView.attributedText.string == "seed hello world from provisional")
    }

    @Test("User edit in provisional range suppresses Soniox provisional updates until endpoint")
    func userEditInProvisionalRangeSuppressesUntilEndpoint() {
        let host = BridgeEndpointTestHost()
        let bridge = ComposeInputDictationBridge(host: host)
        let textView = PastableTextView()

        seed(textView: textView, with: "seed ", selectedRange: NSRange(location: 5, length: 0))
        bridge.setComposeTextView(textView)
        bridge.resetTranscriptState(for: host.activeSessionKey)

        apply(bridge: bridge, update: update(provisional: "hello worl"), host: host)

        simulateUserEdit(
            bridge: bridge,
            textView: textView,
            sessionKey: host.activeSessionKey,
            range: NSRange(location: "seed hello worl".utf16.count, length: 0),
            replacement: "d!"
        )
        #expect(textView.attributedText.string == "seed hello world!")

        apply(
            bridge: bridge,
            update: update(provisional: "hello world from soniox"),
            host: host
        )
        #expect(textView.attributedText.string == "seed hello world!")

        apply(
            bridge: bridge,
            update: update(committed: ["hello world from soniox"], sawEndpoint: true),
            host: host
        )
        #expect(textView.attributedText.string == "seed hello world!")

        apply(
            bridge: bridge,
            update: update(provisional: " plus"),
            host: host
        )
        #expect(textView.attributedText.string == "seed hello world! plus")
    }

    @Test("Suppression skips only first endpoint commit in multi-endpoint update")
    func suppressionSkipsOnlyFirstEndpointCommit() {
        let host = BridgeEndpointTestHost()
        let bridge = ComposeInputDictationBridge(host: host)
        let textView = PastableTextView()

        seed(textView: textView, with: "seed ", selectedRange: NSRange(location: 5, length: 0))
        bridge.setComposeTextView(textView)
        bridge.resetTranscriptState(for: host.activeSessionKey)

        apply(bridge: bridge, update: update(provisional: "alpha"), host: host)
        simulateUserEdit(
            bridge: bridge,
            textView: textView,
            sessionKey: host.activeSessionKey,
            range: NSRange(location: "seed alpha".utf16.count, length: 0),
            replacement: "!"
        )

        apply(
            bridge: bridge,
            update: update(committed: ["alpha", " beta"], sawEndpoint: true),
            host: host
        )
        #expect(textView.attributedText.string == "seed alpha! beta")
    }

    @Test("Finished without endpoint promotes provisional to committed boundary")
    func finishedWithoutEndpointPromotesProvisional() {
        let host = BridgeEndpointTestHost()
        let bridge = ComposeInputDictationBridge(host: host)
        let textView = PastableTextView()

        seed(textView: textView, with: "seed ", selectedRange: NSRange(location: 5, length: 0))
        bridge.setComposeTextView(textView)
        bridge.resetTranscriptState(for: host.activeSessionKey)

        apply(bridge: bridge, update: update(provisional: "tail"), host: host)
        apply(
            bridge: bridge,
            update: update(provisional: "tail", finished: true, hadAnyTokens: false),
            host: host
        )
        #expect(textView.attributedText.string == "seed tail")

        apply(
            bridge: bridge,
            update: update(provisional: " next"),
            host: host
        )
        #expect(textView.attributedText.string == "seed tail next")
    }

    @Test("Finished while suppressed drops provisional and preserves user-local text")
    func finishedWhileSuppressedDropsProvisional() {
        let host = BridgeEndpointTestHost()
        let bridge = ComposeInputDictationBridge(host: host)
        let textView = PastableTextView()

        seed(textView: textView, with: "seed ", selectedRange: NSRange(location: 5, length: 0))
        bridge.setComposeTextView(textView)
        bridge.resetTranscriptState(for: host.activeSessionKey)

        apply(bridge: bridge, update: update(provisional: "draft"), host: host)
        simulateUserEdit(
            bridge: bridge,
            textView: textView,
            sessionKey: host.activeSessionKey,
            range: NSRange(location: 5, length: "draft".utf16.count),
            replacement: "local"
        )
        #expect(textView.attributedText.string == "seed local")

        apply(
            bridge: bridge,
            update: update(provisional: "server provisional"),
            host: host
        )
        apply(
            bridge: bridge,
            update: update(provisional: "server provisional", finished: true, hadAnyTokens: false),
            host: host
        )
        #expect(textView.attributedText.string == "seed local")

        apply(
            bridge: bridge,
            update: update(provisional: " next"),
            host: host
        )
        #expect(textView.attributedText.string == "seed local next")
    }

    @Test("Edit before dictation anchor shifts ownership range")
    func editBeforeDictationAnchorShiftsOwnershipRange() {
        let host = BridgeEndpointTestHost()
        let bridge = ComposeInputDictationBridge(host: host)
        let textView = PastableTextView()

        seed(
            textView: textView,
            with: "AAA BBB CCC",
            selectedRange: NSRange(location: 4, length: 3)
        )
        bridge.setComposeTextView(textView)
        bridge.resetTranscriptState(for: host.activeSessionKey)

        apply(bridge: bridge, update: update(provisional: "dict"), host: host)
        #expect(textView.attributedText.string == "AAA dict CCC")

        simulateUserEdit(
            bridge: bridge,
            textView: textView,
            sessionKey: host.activeSessionKey,
            range: NSRange(location: 0, length: 0),
            replacement: "X"
        )
        #expect(textView.attributedText.string == "XAAA dict CCC")

        apply(bridge: bridge, update: update(provisional: "dict!"), host: host)
        #expect(textView.attributedText.string == "XAAA dict! CCC")
    }

    @Test("Dictation start uses captured selection to replace selected text instead of appending")
    func dictationStartUsesCapturedSelectionForReplacement() {
        let host = BridgeEndpointTestHost()
        let bridge = ComposeInputDictationBridge(host: host)
        let textView = PastableTextView()
        let initial = "alpha BETA omega"
        let selectedRange = NSRange(location: 6, length: 4)

        seed(textView: textView, with: initial, selectedRange: selectedRange)
        bridge.setComposeTextView(textView)
        bridge.setPreferredSelectionRange(selectedRange, for: host.activeSessionKey)

        // Simulate selection collapse caused by the activation touch right before dictation starts.
        textView.selectedRange = NSRange(location: initial.utf16.count, length: 0)
        bridge.resetTranscriptState(for: host.activeSessionKey)

        apply(bridge: bridge, update: update(provisional: "spoken"), host: host)
        apply(
            bridge: bridge,
            update: update(committed: ["spoken"], sawEndpoint: true),
            host: host
        )

        #expect(textView.attributedText.string == "alpha spoken omega")
    }

    @Test("Session key mismatch skips bridge updates")
    func sessionKeyMismatchSkipsBridgeUpdates() {
        let host = BridgeEndpointTestHost()
        let bridge = ComposeInputDictationBridge(host: host)
        let textView = PastableTextView()

        seed(textView: textView, with: "seed ", selectedRange: NSRange(location: 5, length: 0))
        bridge.setComposeTextView(textView)
        bridge.resetTranscriptState(for: host.activeSessionKey)

        bridge.applySegmentUpdate(
            update(provisional: "should_not_apply"),
            baseSnapshot: .empty,
            originSessionKey: "agent:main:test:other"
        )
        bridge.noteUserEdit(
            editedRangeUTF16: NSRange(location: 5, length: 0),
            replacementUTF16Length: 3,
            originSessionKey: "agent:main:test:other"
        )

        #expect(textView.attributedText.string == "seed ")
    }

    @Test("Host fallback applies endpoint model when no UITextView is attached")
    func hostFallbackAppliesEndpointModel() {
        let host = BridgeEndpointTestHost()
        host.setText("seed ", for: host.activeSessionKey)
        let bridge = ComposeInputDictationBridge(host: host)
        bridge.resetTranscriptState(for: host.activeSessionKey)
        let preDictationSnapshot = host.captureComposeDraftSnapshot(for: host.activeSessionKey)

        apply(
            bridge: bridge,
            update: update(provisional: "hello"),
            host: host,
            baseSnapshot: preDictationSnapshot
        )
        #expect(host.currentText(for: host.activeSessionKey) == "seed hello")

        apply(
            bridge: bridge,
            update: update(provisional: " world", committed: ["hello"], sawEndpoint: true),
            host: host,
            baseSnapshot: preDictationSnapshot
        )
        #expect(host.currentText(for: host.activeSessionKey) == "seed hello world")
    }

    private func apply(
        bridge: ComposeInputDictationBridge,
        update: DictationSegmentUpdate,
        host: BridgeEndpointTestHost,
        baseSnapshot: ComposeDraftSnapshot? = nil
    ) {
        bridge.applySegmentUpdate(
            update,
            baseSnapshot: baseSnapshot ?? host.captureComposeDraftSnapshot(for: host.activeSessionKey),
            originSessionKey: host.activeSessionKey
        )
    }

    private func seed(textView: UITextView, with text: String, selectedRange: NSRange) {
        textView.attributedText = NSAttributedString(string: text)
        textView.selectedRange = selectedRange
    }

    private func simulateUserEdit(
        bridge: ComposeInputDictationBridge,
        textView: UITextView,
        sessionKey: String,
        range: NSRange,
        replacement: String
    ) {
        bridge.noteUserEdit(
            editedRangeUTF16: range,
            replacementUTF16Length: replacement.utf16.count,
            originSessionKey: sessionKey
        )

        let mutable = NSMutableAttributedString(attributedString: textView.attributedText)
        mutable.replaceCharacters(in: range, with: replacement)
        textView.attributedText = mutable
        textView.selectedRange = NSRange(location: range.location + replacement.utf16.count, length: 0)
    }

    private func update(
        provisional: String = "",
        committed: [String] = [],
        finished: Bool = false,
        sawEndpoint: Bool = false,
        hadAnyTokens: Bool = true
    ) -> DictationSegmentUpdate {
        DictationSegmentUpdate(
            provisionalText: provisional,
            committedSegments: committed,
            finished: finished,
            sawEndpoint: sawEndpoint,
            hadAnyTokens: hadAnyTokens
        )
    }
}

@MainActor
private final class BridgeEndpointTestHost: DictationComposeDraftHosting {
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
        let _ = moveCursorToEnd
        let prefixLength = baseSnapshot.content.length
        let replacementRange = NSRange(location: prefixLength, length: previousTranscriptUTF16Length)
        let current = NSMutableAttributedString(attributedString: drafts[sessionKey]?.content ?? .init(string: ""))

        let hasExpectedPrefix: Bool = {
            guard current.length >= prefixLength else { return false }
            let prefix = current.attributedSubstring(from: NSRange(location: 0, length: prefixLength))
            return prefix.isEqual(to: baseSnapshot.content)
        }()

        guard hasExpectedPrefix,
              replacementRange.location >= 0,
              replacementRange.length >= 0,
              replacementRange.location + replacementRange.length <= current.length else {
            let fallback = NSMutableAttributedString(attributedString: baseSnapshot.content)
            if replacementText.length > 0 {
                fallback.append(replacementText)
            }
            drafts[sessionKey] = ComposeDraftSnapshot(content: fallback, attachments: baseSnapshot.attachments)
            return
        }

        current.replaceCharacters(in: replacementRange, with: replacementText)
        drafts[sessionKey] = ComposeDraftSnapshot(content: current, attachments: baseSnapshot.attachments)
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

    func currentText(for sessionKey: String) -> String {
        drafts[sessionKey]?.content.string ?? ""
    }
}
