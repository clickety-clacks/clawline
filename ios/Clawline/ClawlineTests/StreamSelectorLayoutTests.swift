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
    @Test("T307 mention picker filters streams and excludes current chat")
    func crossChatMentionPickerFiltersAndExcludesCurrent() {
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
                sessionKey: "agent:main:clawline:user:s_research",
                displayName: "Research Notes",
                kind: "custom",
                orderIndex: 1,
                isBuiltIn: false,
                createdAt: Date(),
                updatedAt: Date()
            ),
            StreamSession(
                sessionKey: "agent:main:clawline:user:s_build",
                displayName: "Build Log",
                kind: "custom",
                orderIndex: 2,
                isBuiltIn: false,
                createdAt: Date(),
                updatedAt: Date()
            ),
        ]

        let result = CrossChatMentionPickerLogic.filteredStreams(
            streams: streams,
            currentSessionKey: "agent:main:main",
            query: "res"
        )

        #expect(result.map(\.displayName) == ["Research Notes"])
    }

    @Test("T307 bare at mention lists every eligible chat except current")
    func crossChatMentionPickerBareAtListsEveryEligibleChat() {
        let streams = [
            StreamSession(
                sessionKey: "agent:main:clawline:user:s_current",
                displayName: "Current",
                kind: "main",
                orderIndex: 0,
                isBuiltIn: true,
                createdAt: Date(),
                updatedAt: Date()
            ),
            StreamSession(
                sessionKey: "agent:main:clawline:user:s_one",
                displayName: "One",
                kind: "custom",
                orderIndex: 1,
                isBuiltIn: false,
                createdAt: Date(),
                updatedAt: Date()
            ),
            StreamSession(
                sessionKey: "agent:main:clawline:user:s_two",
                displayName: "Two",
                kind: "custom",
                orderIndex: 2,
                isBuiltIn: false,
                createdAt: Date(),
                updatedAt: Date()
            ),
            StreamSession(
                sessionKey: "agent:main:clawline:user:s_three",
                displayName: "Three",
                kind: "custom",
                orderIndex: 3,
                isBuiltIn: false,
                createdAt: Date(),
                updatedAt: Date()
            ),
        ]

        let result = CrossChatMentionPickerLogic.filteredStreams(
            streams: streams,
            currentSessionKey: "agent:main:clawline:user:s_current",
            query: ""
        )

        #expect(result.map(\.displayName) == ["One", "Two", "Three"])
    }

    @Test("T307 mention picker filtering uses visible session labels")
    func crossChatMentionPickerFilteringUsesVisibleLabels() {
        let streams = [
            StreamSession(
                sessionKey: "agent:main:clawline:user:s_one",
                displayName: "Dictation",
                kind: "custom",
                orderIndex: 0,
                isBuiltIn: false,
                createdAt: Date(),
                updatedAt: Date()
            ),
            StreamSession(
                sessionKey: "agent:main:clawline:user:s_two",
                displayName: "Clawline",
                kind: "custom",
                orderIndex: 1,
                isBuiltIn: false,
                createdAt: Date(),
                updatedAt: Date()
            ),
            StreamSession(
                sessionKey: "agent:main:clawline:user:s_three",
                displayName: "Notes",
                kind: "custom",
                orderIndex: 2,
                isBuiltIn: false,
                createdAt: Date(),
                updatedAt: Date()
            ),
        ]

        let clawline = CrossChatMentionPickerLogic.filteredStreams(
            streams: streams,
            currentSessionKey: "agent:main:main",
            query: "clawline"
        )
        let dictation = CrossChatMentionPickerLogic.filteredStreams(
            streams: streams,
            currentSessionKey: "agent:main:main",
            query: "dictation"
        )

        #expect(clawline.map(\.displayName) == ["Clawline"])
        #expect(dictation.map(\.displayName) == ["Dictation"])
    }

    @Test("T307 mention picker activates only for leading at-sign and clamps arrow selection")
    func crossChatMentionPickerQueryAndSelection() {
        #expect(CrossChatMentionPickerLogic.query(inputText: "@res", resolvedMention: nil) == "res")
        #expect(CrossChatMentionPickerLogic.query(inputText: "hello @res", resolvedMention: nil) == nil)
        #expect(
            CrossChatMentionPickerLogic.query(
                inputText: "@res",
                resolvedMention: ResolvedCrossChatMention(destinationChatId: "s_1", displayName: "One")
            ) == nil
        )

        let streams = [
            StreamSession(sessionKey: "s_1", displayName: "One", kind: "custom", orderIndex: 0, isBuiltIn: false, createdAt: Date(), updatedAt: Date()),
            StreamSession(sessionKey: "s_2", displayName: "Two", kind: "custom", orderIndex: 1, isBuiltIn: false, createdAt: Date(), updatedAt: Date()),
        ]

        #expect(CrossChatMentionPickerLogic.selectionAfterMoving(currentSessionKey: nil, filteredStreams: streams, step: 1) == "s_2")
        #expect(CrossChatMentionPickerLogic.selectionAfterMoving(currentSessionKey: nil, filteredStreams: streams, step: -1) == "s_1")
        #expect(CrossChatMentionPickerLogic.selectionAfterMoving(currentSessionKey: "s_1", filteredStreams: streams, step: 1) == "s_2")
        #expect(CrossChatMentionPickerLogic.selectionAfterMoving(currentSessionKey: "s_2", filteredStreams: streams, step: 1) == "s_2")
    }

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

    @Test("Stream manager popup keeps a compact action-bar gutter")
    func streamManagerPopupUsesCompactActionBarHeight() {
        let height = StreamSelectorLayout.containerHeight(
            itemCount: 1,
            showsCreateInlineRow: false,
            rowHeight: CGFloat(52),
            rowSpacing: CGFloat(2),
            functionBarHeight: CGFloat(72),
            outerVerticalPadding: CGFloat(20),
            maxAvailableHeight: CGFloat(640),
            minimumPopoverHeight: CGFloat(140)
        )

        #expect(height == CGFloat(164))
    }

    @Test("Stream manager popup keeps its minimum width when titles are short")
    func streamManagerPopupKeepsMinimumWidth() {
        let width = StreamSelectorLayout.popupWidth(
            longestItemWidth: CGFloat(120),
            minimumPopoverWidth: CGFloat(280),
            baselineIdealPopoverWidth: CGFloat(320),
            maximumPopoverWidth: CGFloat(480),
            rowHorizontalInset: CGFloat(12),
            rowContentSpacing: CGFloat(10),
            leadingDotDiameter: CGFloat(8),
            trailingAccessoryReserve: CGFloat(28)
        )

        #expect(width == CGFloat(320))
    }

    @Test("Stream manager popup grows for longer titles but respects the cap")
    func streamManagerPopupWidthTracksContentWithinCap() {
        let contentWidth = CGFloat(410)
        let width = StreamSelectorLayout.popupWidth(
            longestItemWidth: contentWidth,
            minimumPopoverWidth: CGFloat(280),
            baselineIdealPopoverWidth: CGFloat(320),
            maximumPopoverWidth: CGFloat(480),
            rowHorizontalInset: CGFloat(12),
            rowContentSpacing: CGFloat(10),
            leadingDotDiameter: CGFloat(8),
            trailingAccessoryReserve: CGFloat(28)
        )

        #expect(width == CGFloat(480))
    }

    @Test("Stream manager popup width does not exceed the maximum cap")
    func streamManagerPopupWidthRespectsMaximumCap() {
        let width = StreamSelectorLayout.popupWidth(
            longestItemWidth: CGFloat(700),
            minimumPopoverWidth: CGFloat(280),
            baselineIdealPopoverWidth: CGFloat(320),
            maximumPopoverWidth: CGFloat(480),
            rowHorizontalInset: CGFloat(12),
            rowContentSpacing: CGFloat(10),
            leadingDotDiameter: CGFloat(8),
            trailingAccessoryReserve: CGFloat(28)
        )

        #expect(width == CGFloat(480))
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

    @Test("Container height never exceeds the caller's budget, even when the budget is below the preferred minimum")
    func containerHeightRespectsBudgetBelowMinimum() {
        // A very short spatial window can produce a budget that is smaller than
        // minimumPopoverHeight. The helper must clamp to the budget so we never ask the
        // popover system for more height than it can actually allocate — which is exactly
        // the condition that caused the cropping symptom.
        let height = StreamSelectorLayout.containerHeight(
            itemCount: 5,
            showsCreateInlineRow: false,
            rowHeight: CGFloat(52),
            rowSpacing: CGFloat(2),
            functionBarHeight: CGFloat(72),
            outerVerticalPadding: CGFloat(20),
            maxAvailableHeight: CGFloat(90),
            minimumPopoverHeight: CGFloat(140)
        )

        #expect(height == CGFloat(90))
    }

    @Test("Container height falls back to the preferred minimum when content is smaller and budget allows it")
    func containerHeightFallsBackToMinimumWhenContentIsSmall() {
        // With tiny content (single row) and plenty of budget, the container should expand
        // to the preferred minimum so the popup does not look visually collapsed.
        let height = StreamSelectorLayout.containerHeight(
            itemCount: 1,
            showsCreateInlineRow: false,
            rowHeight: CGFloat(20),
            rowSpacing: CGFloat(0),
            functionBarHeight: CGFloat(40),
            outerVerticalPadding: CGFloat(0),
            maxAvailableHeight: CGFloat(640),
            minimumPopoverHeight: CGFloat(140)
        )

        #expect(height == CGFloat(140))
    }

    @Test("List viewport height subtracts the action bar reserve from the container")
    func listViewportHeightSubtractsActionBar() {
        let viewport = StreamSelectorLayout.listViewportHeight(
            containerHeight: CGFloat(320),
            actionBarReservedHeight: CGFloat(72)
        )

        #expect(viewport == CGFloat(248))
    }

    @Test("List viewport height shrinks when the popover allocates less than the ideal")
    func listViewportHeightShrinksWhenContainerIsConstrained() {
        // Simulate the popover system giving us less vertical space than cappedContainerHeight.
        // The viewport must shrink so the list stays inside the visible popup bounds.
        let viewport = StreamSelectorLayout.listViewportHeight(
            containerHeight: CGFloat(180),
            actionBarReservedHeight: CGFloat(72)
        )

        #expect(viewport == CGFloat(108))
    }

    @Test("List viewport height clamps to zero when the container is smaller than the action bar")
    func listViewportHeightClampsToZero() {
        let viewport = StreamSelectorLayout.listViewportHeight(
            containerHeight: CGFloat(40),
            actionBarReservedHeight: CGFloat(72)
        )

        #expect(viewport == CGFloat(0))
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

    @Test("Keyboard selection keeps existing selection when filter still contains it")
    func keyboardSelectionKeepsVisibleSelection() {
        let selection = StreamSelectorLayout.resolvedSelection(
            preferredSessionKey: "agent:main:clawline:user:s_2",
            activeSessionKey: "agent:main:main",
            sessionKeys: [
                "agent:main:main",
                "agent:main:clawline:user:s_2"
            ]
        )

        #expect(selection == "agent:main:clawline:user:s_2")
    }

    @Test("Keyboard selection falls back to active stream or first filtered stream")
    func keyboardSelectionFallsBackToActiveOrFirstFilteredStream() {
        let activeSelection = StreamSelectorLayout.resolvedSelection(
            preferredSessionKey: "agent:main:clawline:user:s_missing",
            activeSessionKey: "agent:main:clawline:user:s_2",
            sessionKeys: [
                "agent:main:main",
                "agent:main:clawline:user:s_2"
            ]
        )
        let firstSelection = StreamSelectorLayout.resolvedSelection(
            preferredSessionKey: "agent:main:clawline:user:s_missing",
            activeSessionKey: "agent:main:clawline:user:s_other",
            sessionKeys: [
                "agent:main:main",
                "agent:main:clawline:user:s_2"
            ]
        )

        #expect(activeSelection == "agent:main:clawline:user:s_2")
        #expect(firstSelection == "agent:main:main")
    }

    @Test("Keyboard selection moves through filtered streams without wrapping")
    func keyboardSelectionMovesThroughFilteredStreams() {
        let sessionKeys = [
            "agent:main:main",
            "agent:main:clawline:user:s_1",
            "agent:main:clawline:user:s_2"
        ]

        #expect(
            StreamSelectorLayout.selectionAfterMoving(
                currentSessionKey: nil,
                sessionKeys: sessionKeys,
                step: 1
            ) == "agent:main:main"
        )
        #expect(
            StreamSelectorLayout.selectionAfterMoving(
                currentSessionKey: "agent:main:main",
                sessionKeys: sessionKeys,
                step: 1
            ) == "agent:main:clawline:user:s_1"
        )
        #expect(
            StreamSelectorLayout.selectionAfterMoving(
                currentSessionKey: "agent:main:clawline:user:s_2",
                sessionKeys: sessionKeys,
                step: 1
            ) == "agent:main:clawline:user:s_2"
        )
        #expect(
            StreamSelectorLayout.selectionAfterMoving(
                currentSessionKey: "agent:main",
                sessionKeys: sessionKeys,
                step: -1
            ) == "agent:main:clawline:user:s_2"
        )
    }

    @Test("Keyboard activation emits selected stream once")
    func keyboardActivationEmitsSelectedStreamOnce() {
        #expect(
            StreamSelectorLayout.activationTarget(
                selectedSessionKey: "agent:main:clawline:user:s_2",
                didActivateSelection: false
            ) == "agent:main:clawline:user:s_2"
        )
        #expect(
            StreamSelectorLayout.activationTarget(
                selectedSessionKey: "agent:main:clawline:user:s_2",
                didActivateSelection: true
            ) == nil
        )
        #expect(
            StreamSelectorLayout.activationTarget(
                selectedSessionKey: nil,
                didActivateSelection: false
            ) == nil
        )
    }
}
