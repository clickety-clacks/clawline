//
//  PromptEditorControllerTests.swift
//  ClawlineTests
//
//  Created by Codex on 6/23/26.
//

import Foundation
import Testing
@testable import Clawline

@MainActor
struct PromptEditorControllerTests {
    @Test("Prompt editor selection policies clamp ranges against TextKit length")
    func selectionPoliciesClampAgainstDocumentLength() {
        let controller = PromptEditorController()
        _ = controller.recordParentMutation(reason: "test")
        let snapshot = PromptEditorSnapshot(
            revision: controller.revision,
            contentLength: 8,
            selectedRange: NSRange(location: 7, length: 4),
            isComposing: false,
            isFocused: true
        )

        #expect(
            controller.selectionRange(
                policy: .preserve,
                replacementRange: NSRange(location: 2, length: 3),
                replacementLength: 4,
                documentLengthAfterReplacement: 10,
                currentSelection: NSRange(location: 8, length: 5)
            ) == NSRange(location: 8, length: 2)
        )
        #expect(
            controller.selectionRange(
                policy: .moveToInsertedEnd,
                replacementRange: NSRange(location: 2, length: 3),
                replacementLength: 4,
                documentLengthAfterReplacement: 10,
                currentSelection: NSRange(location: 0, length: 0)
            ) == NSRange(location: 6, length: 0)
        )
        #expect(
            controller.selectionRange(
                policy: .selectReplacement,
                replacementRange: NSRange(location: 9, length: 4),
                replacementLength: 4,
                documentLengthAfterReplacement: 10,
                currentSelection: NSRange(location: 0, length: 0)
            ) == NSRange(location: 9, length: 1)
        )
        #expect(
            controller.selectionRange(
                policy: .restoreSnapshotSelection,
                replacementRange: NSRange(location: 0, length: 0),
                replacementLength: 0,
                documentLengthAfterReplacement: 8,
                currentSelection: NSRange(location: 1, length: 0),
                snapshot: snapshot
            ) == NSRange(location: 7, length: 1)
        )
        #expect(
            controller.selectionRange(
                policy: .documentEnd,
                replacementRange: NSRange(location: 0, length: 0),
                replacementLength: 0,
                documentLengthAfterReplacement: 10,
                currentSelection: NSRange(location: 1, length: 0)
            ) == NSRange(location: 10, length: 0)
        )
    }

    @Test("Prompt editor stale snapshot restore falls back to current selection")
    func staleSnapshotRestoreFallsBackToCurrentSelection() {
        let controller = PromptEditorController()
        let staleSnapshot = PromptEditorSnapshot(
            revision: 99,
            contentLength: 12,
            selectedRange: NSRange(location: 11, length: 1),
            isComposing: false,
            isFocused: true
        )

        let selection = controller.selectionRange(
            policy: .restoreSnapshotSelection,
            replacementRange: NSRange(location: 0, length: 0),
            replacementLength: 0,
            documentLengthAfterReplacement: 5,
            currentSelection: NSRange(location: 4, length: 5),
            snapshot: staleSnapshot
        )

        #expect(selection == NSRange(location: 4, length: 1))
    }

    @Test("Prompt editor revisions distinguish parent echoes from editor changes")
    func revisionsDistinguishParentEchoesFromEditorChanges() {
        let controller = PromptEditorController()

        let parentSource = controller.recordParentMutation(reason: "replaceDraft")
        #expect(controller.shouldSuppressEcho(from: parentSource))

        let editorSource = PromptEditorMutationSource(
            revision: parentSource.revision,
            origin: .editor,
            reason: "textDidChange"
        )
        #expect(!controller.shouldSuppressEcho(from: editorSource))

        let event = controller.recordEditorDraftChange(
            content: NSAttributedString(string: "draft"),
            editKind: .user
        )
        guard case let .draftChanged(revision, content, editKind) = event else {
            Issue.record("Expected draftChanged event")
            return
        }

        #expect(revision == 2)
        #expect(content.length == 5)
        #expect(editKind == .user)
        #expect(!controller.shouldSuppressEcho(from: parentSource))
    }
}
