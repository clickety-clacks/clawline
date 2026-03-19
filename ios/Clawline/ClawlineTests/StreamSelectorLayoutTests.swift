//
//  StreamSelectorLayoutTests.swift
//  ClawlineTests
//
//  Created by Codex on 2/13/26.
//

import Testing
import CoreGraphics
import Foundation
@testable import Clawline

struct StreamSelectorLayoutTests {

    @Test("Short stream list uses content-driven height")
    func shortListUsesContentHeight() {
        let height = StreamSelectorLayout.containerHeight(
            itemCount: 3,
            showsCreateInlineRow: false,
            rowHeight: CGFloat(44),
            rowSpacing: CGFloat(0),
            functionBarHeight: CGFloat(52),
            outerVerticalPadding: CGFloat(16),
            maxAvailableHeight: CGFloat(640),
            minimumPopoverHeight: CGFloat(140)
        )

        #expect(height == CGFloat(216))
    }

    @Test("Long stream list caps height and relies on internal scrolling")
    func longListUsesCappedHeight() {
        let height = StreamSelectorLayout.containerHeight(
            itemCount: 22,
            showsCreateInlineRow: false,
            rowHeight: CGFloat(44),
            rowSpacing: CGFloat(0),
            functionBarHeight: CGFloat(52),
            outerVerticalPadding: CGFloat(16),
            maxAvailableHeight: CGFloat(340),
            minimumPopoverHeight: CGFloat(140)
        )

        #expect(height == CGFloat(340))
    }

    @Test("Overflow detection stays false when content fits")
    func overflowDetectionRespectsFitContent() {
        let isOverflowing = StreamSelectorLayout.isOverflowing(
            itemCount: 3,
            showsCreateInlineRow: false,
            rowHeight: CGFloat(52),
            rowSpacing: CGFloat(8),
            functionBarHeight: CGFloat(58),
            outerVerticalPadding: CGFloat(16),
            maxAvailableHeight: CGFloat(480),
            minimumPopoverHeight: CGFloat(140)
        )

        #expect(isOverflowing == false)
    }

    @Test("Overflow detection turns on only when capped")
    func overflowDetectionRespectsCap() {
        let isOverflowing = StreamSelectorLayout.isOverflowing(
            itemCount: 8,
            showsCreateInlineRow: false,
            rowHeight: CGFloat(52),
            rowSpacing: CGFloat(8),
            functionBarHeight: CGFloat(58),
            outerVerticalPadding: CGFloat(16),
            maxAvailableHeight: CGFloat(320),
            minimumPopoverHeight: CGFloat(140)
        )

        #expect(isOverflowing == true)
    }

    @Test("Stream filter matches display names case-insensitively")
    func streamFilterMatchesCaseInsensitively() {
        let streams = [
            StreamSession(
                sessionKey: "agent:main:main",
                displayName: "Main",
                kind: "main",
                orderIndex: 0,
                isBuiltIn: true,
                createdAt: Date(),
                updatedAt: Date()
            ),
            StreamSession(
                sessionKey: "agent:main:clawline:user:s_1",
                displayName: "Research Notes",
                kind: "custom",
                orderIndex: 1,
                isBuiltIn: false,
                createdAt: Date(),
                updatedAt: Date()
            )
        ]

        let filtered = StreamSelectorLayout.filter(streams: streams, query: "research")

        #expect(filtered.count == 1)
        #expect(filtered.first?.displayName == "Research Notes")
    }

    @Test("Blank stream filter returns all streams")
    func blankStreamFilterReturnsAll() {
        let streams = [
            StreamSession(
                sessionKey: "agent:main:main",
                displayName: "Main",
                kind: "main",
                orderIndex: 0,
                isBuiltIn: true,
                createdAt: Date(),
                updatedAt: Date()
            ),
            StreamSession(
                sessionKey: "agent:main:clawline:user:s_2",
                displayName: "Planning",
                kind: "custom",
                orderIndex: 1,
                isBuiltIn: false,
                createdAt: Date(),
                updatedAt: Date()
            )
        ]

        let filtered = StreamSelectorLayout.filter(streams: streams, query: "   ")

        #expect(filtered.count == streams.count)
    }

    @Test("Popup reorder state moves the full visible session-key list immediately")
    func popupReorderStateMovesVisibleSessionKeysImmediately() {
        var state = StreamManagerSheetReorderState()
        state.applyCanonical(["main", "alpha", "bravo"])

        let reordered = state.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)

        #expect(reordered == ["bravo", "main", "alpha"])
        #expect(state.displayedSessionKeys == ["bravo", "main", "alpha"])
        #expect(state.canonicalSessionKeys == ["main", "alpha", "bravo"])
    }

    @Test("Popup reorder state snaps to canonical order when snapshot order changes")
    func popupReorderStateSnapsToCanonicalSnapshotOrder() {
        var state = StreamManagerSheetReorderState()
        state.applyCanonical(["main", "alpha", "bravo"])
        _ = state.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)

        state.applyCanonical(["alpha", "main", "bravo"])

        #expect(state.displayedSessionKeys == ["alpha", "main", "bravo"])
        #expect(state.canonicalSessionKeys == ["alpha", "main", "bravo"])
    }

    @Test("Popup reorder state rolls back to canonical order on server failure")
    func popupReorderStateRollsBackToCanonicalOrder() {
        var state = StreamManagerSheetReorderState()
        state.applyCanonical(["main", "alpha", "bravo"])
        _ = state.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)

        state.rollback()

        #expect(state.displayedSessionKeys == ["main", "alpha", "bravo"])
    }

    @Test("Popup reorder stays disabled during search")
    func popupReorderDisablesDuringSearch() {
        let enabled = StreamManagerSheetReorderState.canReorder(
            searchQuery: "alpha",
            isEditing: false,
            hasPendingRemoval: false,
            hasPendingCreateRows: false,
            isMutatingStreams: false,
            streamCount: 3
        )

        #expect(enabled == false)
    }
}
