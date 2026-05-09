import Testing
import CoreGraphics
@testable import Clawline

struct ScrollToBottomUnreadTests {
    @Test("Appended message IDs: previous nil yields empty")
    func appendedIdsPreviousNil() {
        let result = MessageFlowCollectionViewController.appendedMessageIDs(
            previousLastMessageId: nil,
            messageIDs: ["a", "b"]
        )
        #expect(result.isEmpty)
    }

    @Test("Appended message IDs: returns IDs after previous last")
    func appendedIdsAfterPrevious() {
        let result = MessageFlowCollectionViewController.appendedMessageIDs(
            previousLastMessageId: "b",
            messageIDs: ["a", "b", "c", "d"]
        )
        #expect(result == ["c", "d"])
    }

    @Test("Appended message IDs: previous last at end yields empty")
    func appendedIdsPreviousAtEnd() {
        let result = MessageFlowCollectionViewController.appendedMessageIDs(
            previousLastMessageId: "d",
            messageIDs: ["a", "b", "c", "d"]
        )
        #expect(result.isEmpty)
    }

    @Test("Appended message IDs: previous not found yields empty")
    func appendedIdsPreviousMissing() {
        let result = MessageFlowCollectionViewController.appendedMessageIDs(
            previousLastMessageId: "x",
            messageIDs: ["a", "b", "c"]
        )
        #expect(result.isEmpty)
    }

    @Test("Bottom fallback: incremental append must not schedule autojump")
    func bottomFallbackSkipsIncrementalAppend() {
        let shouldSchedule = MessageFlowCollectionViewController.shouldScheduleBottomFallbackAfterApply(
            hasAuthoritativeRestoreTarget: false,
            restorePhaseIsNone: true,
            isIncrementalAppend: true,
            previousLastMessageId: "m1"
        )
        #expect(shouldSchedule == false)
    }

    @Test("Bottom fallback: first population may schedule one-time placement")
    func bottomFallbackAllowsFirstPopulation() {
        let shouldSchedule = MessageFlowCollectionViewController.shouldScheduleBottomFallbackAfterApply(
            hasAuthoritativeRestoreTarget: false,
            restorePhaseIsNone: true,
            isIncrementalAppend: false,
            previousLastMessageId: nil
        )
        #expect(shouldSchedule == true)
    }

    @Test("Scroll-to-bottom falls back to absolute bottom when no anchor exists")
    func scrollToBottomFallsBackWithoutAnchor() {
        let shouldFallback = MessageFlowCollectionViewController.shouldFallbackToAbsoluteBottom(
            lastMessageId: "m1",
            hasMessageAnchor: false
        )
        #expect(shouldFallback == true)
    }

    @Test("Scroll-to-bottom uses anchor path when last message anchor exists")
    func scrollToBottomUsesAnchorWhenAvailable() {
        let shouldFallback = MessageFlowCollectionViewController.shouldFallbackToAbsoluteBottom(
            lastMessageId: "m1",
            hasMessageAnchor: true
        )
        #expect(shouldFallback == false)
    }

    @Test("Automated bottom scroll is disqualified when a non-bottom restore target exists")
    func automatedBottomScrollDisqualifiedForNonBottomRestoreTarget() {
        let shouldSchedule = MessageFlowCollectionViewController.shouldScheduleAutomatedBottomScroll(
            hasAuthoritativeRestoreTarget: true
        )
        #expect(shouldSchedule == false)
    }

    @Test("Automated bottom scroll stays enabled for at-bottom state")
    func automatedBottomScrollAllowedForAtBottomState() {
        let shouldSchedule = MessageFlowCollectionViewController.shouldScheduleAutomatedBottomScroll(
            hasAuthoritativeRestoreTarget: false
        )
        #expect(shouldSchedule == true)
    }

    @Test("Pinned inset adjustment is disqualified when a non-bottom restore target exists")
    func pinnedInsetAdjustmentDisqualifiedForNonBottomRestoreTarget() {
        let shouldAdjust = MessageFlowCollectionViewController.shouldAdjustForBottomInsetPinnedPosition(
            hasAuthoritativeRestoreTarget: true,
            isPinnedToBottomIntent: true,
            isActivelyDraggingOrTracking: false
        )
        #expect(shouldAdjust == false)
    }

    @Test("Viewport compensation is disqualified when a non-bottom restore target exists")
    func viewportCompensationDisqualifiedForNonBottomRestoreTarget() {
        let shouldCompensate = MessageFlowCollectionViewController.shouldApplyViewportAnchorCompensation(
            hasAuthoritativeRestoreTarget: true
        )
        #expect(shouldCompensate == false)
    }

    @Test("SBB resting bottom excludes footer reveal range")
    func sbbRestingBottomExcludesFooterRevealRange() {
        let contentHeight: CGFloat = 1_200
        let boundsHeight: CGFloat = 700
        let topInset: CGFloat = 40
        let bottomInset: CGFloat = 180
        let footerHeight = SessionMetadataFooterCell.topPadding
            + SessionMetadataFooterCell.actionRegionHeight
            + SessionMetadataFooterCell.bottomPadding
        let restingContentHeight = MessageFlowCollectionViewController.restingBottomContentHeight(
            contentSizeHeight: contentHeight,
            footerHeight: footerHeight,
            hasFooter: true
        )
        let restingBottom = MessageFlowCollectionViewController.bottomOffsetMaxY(
            contentHeight: restingContentHeight,
            boundsHeight: boundsHeight,
            topInset: topInset,
            bottomInset: bottomInset
        )
        let trueBottom = MessageFlowCollectionViewController.bottomOffsetMaxY(
            contentHeight: contentHeight,
            boundsHeight: boundsHeight,
            topInset: topInset,
            bottomInset: bottomInset
        )

        #expect(trueBottom - restingBottom == footerHeight)
        #expect(MessageFlowCollectionViewController.footerRevealAlpha(
            contentOffsetY: restingBottom,
            restingBottomOffsetY: restingBottom,
            trueBottomOffsetY: trueBottom,
        ) == 0)
        #expect(MessageFlowCollectionViewController.footerRevealAlpha(
            contentOffsetY: restingBottom - 1,
            restingBottomOffsetY: restingBottom,
            trueBottomOffsetY: trueBottom
        ) == 0)
    }

    @Test("User scroll past SBB resting bottom reveals footer")
    func userScrollPastSBBRestingBottomRevealsFooter() {
        let restingBottom: CGFloat = 440
        let trueBottom: CGFloat = 500

        #expect(MessageFlowCollectionViewController.footerRevealAlpha(
            contentOffsetY: restingBottom,
            restingBottomOffsetY: restingBottom,
            trueBottomOffsetY: trueBottom,
        ) == 0)
        #expect(MessageFlowCollectionViewController.footerRevealAlpha(
            contentOffsetY: restingBottom + 1,
            restingBottomOffsetY: restingBottom,
            trueBottomOffsetY: trueBottom
        ) > 0)
        #expect(MessageFlowCollectionViewController.footerRevealAlpha(
            contentOffsetY: (restingBottom + trueBottom) / 2,
            restingBottomOffsetY: restingBottom,
            trueBottomOffsetY: trueBottom,
        ) == 0.5)
        #expect(MessageFlowCollectionViewController.footerRevealAlpha(
            contentOffsetY: trueBottom,
            restingBottomOffsetY: restingBottom,
            trueBottomOffsetY: trueBottom
        ) == 1)
    }

    @Test("Initial footer cell alpha is resolved without waiting for scroll")
    func initialFooterCellAlphaIsResolvedWithoutWaitingForScroll() {
        let restingBottom: CGFloat = 440
        let trueBottom: CGFloat = 500

        #expect(MessageFlowCollectionViewController.initialFooterCellAlpha(
            contentOffsetY: restingBottom,
            restingBottomOffsetY: restingBottom,
            trueBottomOffsetY: trueBottom
        ) == 0)
        #expect(MessageFlowCollectionViewController.initialFooterCellAlpha(
            contentOffsetY: (restingBottom + trueBottom) / 2,
            restingBottomOffsetY: restingBottom,
            trueBottomOffsetY: trueBottom
        ) == 0.5)
        #expect(MessageFlowCollectionViewController.initialFooterCellAlpha(
            contentOffsetY: trueBottom,
            restingBottomOffsetY: restingBottom,
            trueBottomOffsetY: trueBottom
        ) == 1)
    }
}
