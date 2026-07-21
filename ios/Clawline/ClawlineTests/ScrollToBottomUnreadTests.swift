import Testing
import CoreGraphics
import Foundation
import UIKit
@testable import Clawline

@MainActor
@Suite(.serialized)
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

#if !targetEnvironment(macCatalyst)
    @Test("R1662-01/R6 iPhone production scroll path fades footer to zero at chat-bubble bottom")
    func r1662_01_r6_iPhoneProductionScrollPathFadesFooterToZeroAtChatBubbleBottom() async throws {
        let (controller, viewModel) = try await makeFooterScrollController()
        defer { viewModel.onDisappear() }

        try await settleProjectionBottom(controller)

        #expect(MessageFlowCollectionViewController.hidesFooterAtRestingBottom)
        #expect(controller.footerAlphaForTesting == 0)
        #expect(controller.displayedFooterAlphaForTesting == 0)
    }

    @Test("R1662-02/R6 iPhone production scroll path progressively reveals away from chat-bubble bottom")
    func r1662_02_r6_iPhoneProductionScrollPathProgressivelyRevealsAwayFromChatBubbleBottom() async throws {
        let (controller, viewModel) = try await makeFooterScrollController()
        defer { viewModel.onDisappear() }

        try await settleProjectionBottom(controller)
        let chatBubbleBottom = controller.chatBubbleBottomOffsetYForTesting
        controller.setChatScrollOffsetYForTesting(
            chatBubbleBottom + (SessionMetadataFooterCell.fadeRevealRange / 2)
        )
        let midpointAlpha = controller.displayedFooterAlphaForTesting
        controller.setChatScrollOffsetYForTesting(
            chatBubbleBottom + SessionMetadataFooterCell.fadeRevealRange
        )

        #expect(midpointAlpha == 0.5)
        #expect(controller.displayedFooterAlphaForTesting == 1)
    }

    @Test("R1662-R7 footer content and controls remain unchanged by scroll-state updates")
    func r1662_r7_footerContentAndControlsRemainUnchangedByScrollStateUpdates() async throws {
        let (controller, viewModel) = try await makeFooterScrollController()
        defer { viewModel.onDisappear() }

        let footerFrame = try #require(controller.footerFrameForTesting)
        try await settleProjectionBottom(controller)
        controller.setChatScrollOffsetYForTesting(
            controller.chatBubbleBottomOffsetYForTesting + SessionMetadataFooterCell.fadeRevealRange
        )

        #expect(controller.footerFrameForTesting == footerFrame)
    }

    @Test("R1662-R7 filtered session anchors fade to its last displayed chat bubble")
    func r1662_r7_filteredSessionAnchorsFadeToLastDisplayedChatBubble() async throws {
        let (controller, viewModel) = try await makeFooterScrollController(streamSearchQuery: "message 0")
        defer { viewModel.onDisappear() }

        try await settleProjectionBottom(controller)

        #expect(controller.chatBubbleBottomOffsetYForTesting.isFinite)
        #expect(controller.displayedFooterAlphaForTesting == 0)
    }
#endif

#if targetEnvironment(macCatalyst)
    @Test("R1662-05 Catalyst production resting viewport contains its always-visible footer")
    func r1662_05_catalystProductionRestingViewportContainsAlwaysVisibleFooter() async throws {
        let (controller, viewModel) = try await makeFooterScrollController()
        defer { viewModel.onDisappear() }

        controller.scrollToBottom(animated: false)
        let footerFrame = try #require(controller.footerFrameForTesting)
        #expect(MessageFlowCollectionViewController.hidesFooterAtRestingBottom == false)
        #expect(MessageFlowCollectionViewController.excludesFooterRevealRangeAtRestingBottom == false)
        #expect(controller.footerViewportBoundsForTesting.intersects(footerFrame))
        #expect(controller.footerAlphaForTesting == 1)
    }
#endif

    private func makeFooterScrollController(
        streamSearchQuery: String = ""
    ) async throws -> (MessageFlowCollectionViewController, ChatViewModel) {
        let sessionKey = "agent:main:clawline:user:s_t1662"
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let chatService = TestChatService()
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: UploadService(auth: auth),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
        viewModel.setActiveSessionKeyForTesting(sessionKey)

        for index in 0..<12 {
            viewModel.debugUpsertMessage(Message(
                id: "t1662-\(index)",
                role: index.isMultiple(of: 2) ? .user : .assistant,
                content: String(repeating: "Footer regression production-path message \(index). ", count: 8),
                timestamp: .now,
                streaming: false,
                attachments: [],
                deviceId: nil,
                sessionKey: sessionKey
            ), isServer: true)
        }
        #expect(viewModel.messages(for: sessionKey).count == 12)
        if !streamSearchQuery.isEmpty {
            viewModel.requestMessageProjection(
                for: sessionKey,
                showOnlyUserMessages: false,
                searchQuery: streamSearchQuery
            )
            for _ in 0..<100 {
                if viewModel.messageProjection(
                    for: sessionKey,
                    showOnlyUserMessages: false,
                    searchQuery: streamSearchQuery
                ) != nil {
                    break
                }
                try await Task.sleep(for: .milliseconds(10))
            }
        }

        let controller = MessageFlowCollectionViewController(nibName: nil, bundle: nil)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        controller.update(
            viewModel: viewModel,
            isCompact: true,
            isActiveSession: true,
            isRenderPolicyFrozen: false,
            isInputActive: false,
            keepsKeyboardPinned: false,
            isTypingActive: false,
            topInset: 40,
            truncationBottomInset: 0,
            firstUnreadMessageId: nil,
            unreadCount: 0,
            sessionKey: sessionKey,
            streamSearchQuery: streamSearchQuery
        )
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        for _ in 0..<100 where controller.footerFrameForTesting == nil {
            try await Task.sleep(for: .milliseconds(10))
            controller.view.layoutIfNeeded()
        }
        return (controller, viewModel)
    }

    private func settleProjectionBottom(_ controller: MessageFlowCollectionViewController) async throws {
        controller.scheduleScrollToBottom(animated: false, attempts: 1)
        for _ in 0..<100 where controller.displayedFooterAlphaForTesting == nil {
            try await Task.sleep(for: .milliseconds(10))
            controller.view.layoutIfNeeded()
        }
    }

    @Test("Bounds-only layout changes skip redundant snapshot update")
    func boundsOnlyLayoutChangeSkipsSnapshotUpdate() {
        let shouldRunUpdate = MessageFlowCollectionViewController.shouldRunUpdateAfterBoundsChange(
            measurementInputsChanged: false,
            hadPendingFullReconfigure: false
        )
        #expect(shouldRunUpdate == false)
    }

    @Test("Bounds change refreshes snapshot when measurement inputs changed")
    func boundsChangeRefreshesWhenMeasurementInputsChanged() {
        let shouldRunUpdate = MessageFlowCollectionViewController.shouldRunUpdateAfterBoundsChange(
            measurementInputsChanged: true,
            hadPendingFullReconfigure: false
        )
        #expect(shouldRunUpdate == true)
    }

    @Test("Bounds change preserves pending full reconfigure")
    func boundsChangePreservesPendingFullReconfigure() {
        let shouldRunUpdate = MessageFlowCollectionViewController.shouldRunUpdateAfterBoundsChange(
            measurementInputsChanged: false,
            hadPendingFullReconfigure: true
        )
        #expect(shouldRunUpdate == true)
    }
}
