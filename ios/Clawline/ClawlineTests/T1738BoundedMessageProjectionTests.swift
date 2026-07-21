import Foundation
import Testing
import UIKit
@testable import Clawline

@MainActor
private final class T1738UploadService: UploadServicing {
    func upload(data _: Data, mimeType _: String, filename _: String?) async throws -> String {
        "asset-t1738"
    }

    func download(assetId _: String) async throws -> Data {
        Data()
    }
}

@Suite(.serialized)
struct T1738BoundedMessageProjectionTests {
    @Test("T1738: window state is bounded for first activation and revisit", arguments: [50, 500, 5_000])
    func windowStateIsBounded(totalCount: Int) {
        let first = BoundedMessageWindow.updating(
            previous: nil,
            totalCount: totalCount,
            limit: 50,
            followsTail: true
        )
        let revisit = BoundedMessageWindow.updating(
            previous: first,
            totalCount: totalCount,
            limit: 50,
            followsTail: first.reachesTail
        )

        #expect(first.range.count == min(totalCount, 50))
        #expect(revisit == first)
        #expect(first.reachesTail)
    }

    @Test("T1738: historical append retains bounds while tail append follows tail")
    func appendWindowBehavior() {
        let tail = BoundedMessageWindow.tail(totalCount: 500, limit: 50)
        let appendedTail = BoundedMessageWindow.updating(
            previous: tail,
            totalCount: 501,
            limit: 50,
            followsTail: true
        )
        let historical = BoundedMessageWindow(lowerBound: 200, upperBound: 250, totalCount: 500)
        let appendedHistorical = BoundedMessageWindow.updating(
            previous: historical,
            totalCount: 501,
            limit: 50,
            followsTail: false
        )

        #expect(appendedTail.range == 451 ..< 501)
        #expect(appendedHistorical.range == 200 ..< 250)
    }

    @Test("T1738: exact arrival ceiling is incremental and sentinel overflow is not")
    func arrivalSentinelClassification() {
        let exact = (0 ..< 99).map { "arrival-\($0)" }
        let overflow = (0 ..< 100).map { "arrival-\($0)" }

        #expect(MessageFlowCollectionViewController.isBoundedIncrementalArrival(
            previousLastMessageId: "previous",
            appendedMessageIDs: exact
        ))
        #expect(!MessageFlowCollectionViewController.isBoundedIncrementalArrival(
            previousLastMessageId: "previous",
            appendedMessageIDs: overflow
        ))
    }

    @Test("T1738: older/newer shifts overlap by half and direct target stays bounded")
    func shiftsAndDirectTargetStayBounded() {
        let middle = BoundedMessageWindow(lowerBound: 200, upperBound: 250, totalCount: 5_000)
        let older = middle.shifted(older: true, limit: 50)
        let newer = middle.shifted(older: false, limit: 50)
        let target = BoundedMessageWindow.containing(targetIndex: 2_345, totalCount: 5_000, limit: 50)

        #expect(older.range == 175 ..< 225)
        #expect(newer.range == 225 ..< 275)
        #expect(target.range.count == 50)
        #expect(target.range.contains(2_345))
    }

    @Test("T1738: empty and sparse projections clamp every window operation")
    func emptyAndSparseProjectionWindowsClamp() {
        let empty = BoundedMessageWindow.tail(totalCount: 0, limit: 50)
        let sparse = BoundedMessageWindow.tail(totalCount: 3, limit: 50)
        let sparseOlder = sparse.shifted(older: true, limit: 50)
        let sparseNewer = sparse.shifted(older: false, limit: 50)
        let sparseTarget = BoundedMessageWindow.containing(targetIndex: 1, totalCount: 3, limit: 50)

        #expect(empty.range.isEmpty)
        #expect(sparse.range == 0 ..< 3)
        #expect(sparseOlder == sparse)
        #expect(sparseNewer == sparse)
        #expect(sparseTarget == sparse)
    }

    @Test("T1738: transcript switches slice only the fixed message window", arguments: [50, 500, 5_000])
    func transcriptWindowIsBounded(totalCount: Int) {
        let messages = makeMessages(count: totalCount)
        let index = MessageProjectionIndex(messages: messages, revision: 1)
        let projection = index.snapshot(base: .transcript)
        let windowCount = MessageFlowCollectionViewController.stagedMaterializationTailWindowCount(
            isShowingOnlyUserMessages: false
        )
        let lower = max(0, projection.count - windowCount)
        let slice = projection.messages(in: lower ..< projection.count)

        #expect(projection.count == totalCount)
        #expect(slice.count == min(totalCount, windowCount))
        #expect(slice.last?.id == messages.last?.id)
    }

    @Test("T1738: user-only projection is indexed before activation")
    func userOnlyProjectionUsesCachedTranscriptIndices() {
        let messages = makeMessages(count: 5_000)
        let index = MessageProjectionIndex(messages: messages, revision: 7)
        let projection = index.snapshot(base: .userOnly)
        let windowCount = MessageFlowCollectionViewController.stagedMaterializationTailWindowCount(
            isShowingOnlyUserMessages: true
        )
        let slice = projection.messages(in: max(0, projection.count - windowCount) ..< projection.count)

        #expect(projection.count == 2_500)
        #expect(slice.count == 100)
        #expect(slice.allSatisfy { $0.role == .user })
    }

    @Test("T1738: append updates projection indexes without changing prior identity")
    func appendUpdatesProjectionIndexes() {
        let original = makeMessages(count: 500)
        var index = MessageProjectionIndex(messages: original, revision: 1)
        let firstAppend = makeMessage(index: 500)
        let secondAppend = makeMessage(index: 501)
        let afterFirstAppend = original + [firstAppend]
        let afterSecondAppend = afterFirstAppend + [secondAppend]

        index.update(
            messages: afterFirstAppend,
            revision: 2,
            mutation: .insert(index: 500, message: firstAppend)
        )
        index.update(
            messages: afterSecondAppend,
            revision: 3,
            mutation: .insert(index: 501, message: secondAppend)
        )
        let transcript = index.snapshot(base: .transcript)
        let users = index.snapshot(base: .userOnly)

        #expect(transcript.projectedIndex(of: "m-0") == 0)
        #expect(transcript.projectedIndex(of: "m-501") == 501)
        #expect(transcript.messageIds(after: "m-499") == ["m-500", "m-501"])
        #expect(transcript.messageIds(after: "m-499", limit: 1) == ["m-500"])
        #expect(users.count == 251)
    }

    @Test("T1738: search projection computation returns ordered base-space indexes")
    func searchProjectionIsOrderedAndBaseScoped() {
        let messages = (0 ..< 500).map { index in
            Message(
                id: "search-\(index)",
                role: index.isMultiple(of: 2) ? .user : .assistant,
                content: index.isMultiple(of: 25) ? "needle \(index)" : "plain \(index)",
                timestamp: Date(timeIntervalSince1970: TimeInterval(index)),
                streaming: false,
                attachments: [],
                deviceId: nil,
                sessionKey: "T1738"
            )
        }
        let index = MessageProjectionIndex(messages: messages, revision: 3)

        let transcriptMatches = index.searchInput(base: .transcript)
            .matchingTranscriptIndices(query: "needle")
        let userMatches = index.searchInput(base: .userOnly)
            .matchingTranscriptIndices(query: "needle")

        #expect(transcriptMatches == Array(stride(from: 0, to: 500, by: 25)))
        #expect(userMatches == Array(stride(from: 0, to: 500, by: 50)))
    }

    @Test("T1738: stale search completion cannot retire replacement ownership")
    func staleSearchCompletionCannotRetireReplacementOwnership() {
        var ownership = MessageProjectionBuildOwnership<String>()
        let staleBuildID = ownership.begin(for: "selected-query")
        let replacementBuildID = ownership.begin(for: "selected-query")
        let staleFinished = ownership.finish(for: "selected-query", buildID: staleBuildID)
        let replacementFinished = ownership.finish(for: "selected-query", buildID: replacementBuildID)
        let replacementFinishedAgain = ownership.finish(for: "selected-query", buildID: replacementBuildID)

        #expect(!staleFinished)
        #expect(replacementFinished)
        #expect(!replacementFinishedAgain)
    }

    @Test("T1738: auxiliary snapshot fan-out has a fixed formula")
    func maximumSnapshotCountIsBounded() {
        #expect(MessageFlowCollectionViewController.maximumBoundedSnapshotItemCount(messageWindowCount: 50) == 152)
        #expect(MessageFlowCollectionViewController.maximumBoundedSnapshotItemCount(messageWindowCount: 100) == 302)
    }

    @Test("T1738: projection lookup is inert until selected and stable revisit does not rebuild")
    @MainActor
    func selectedSearchProjectionBuildIsExplicitAndStable() async throws {
        let viewModel = makeViewModel()
        defer { viewModel.prepareForReplacement() }
        let sessionKey = "agent:main:clawline:user:t1738-search"
        for index in 0 ..< 200 {
            viewModel.debugUpsertMessage(makeMessage(index: index, sessionKey: sessionKey), isServer: true)
        }

        let beforeLookup = viewModel.messageProjectionPublicationSequence
        #expect(viewModel.messageProjection(
            for: sessionKey,
            showOnlyUserMessages: false,
            searchQuery: "message 19"
        ) == nil)
        await Task.yield()
        #expect(viewModel.messageProjectionPublicationSequence == beforeLookup)

        viewModel.requestMessageProjection(
            for: sessionKey,
            showOnlyUserMessages: false,
            searchQuery: "message 19"
        )
        let projection = try await waitForProjection(
            viewModel: viewModel,
            sessionKey: sessionKey,
            query: "message 19"
        )
        #expect(projection.count == 11)
        let builtSequence = viewModel.messageProjectionPublicationSequence

        viewModel.requestMessageProjection(
            for: sessionKey,
            showOnlyUserMessages: false,
            searchQuery: "message 19"
        )
        await Task.yield()
        #expect(viewModel.messageProjectionPublicationSequence == builtSequence)

        viewModel.debugUpsertMessage(
            Message(
                id: "m-0",
                role: .user,
                content: "message 19 replacement",
                timestamp: Date(timeIntervalSince1970: 0),
                streaming: false,
                attachments: [],
                deviceId: nil,
                sessionKey: sessionKey
            ),
            isServer: true
        )
        #expect(viewModel.messageProjection(
            for: sessionKey,
            showOnlyUserMessages: false,
            searchQuery: "message 19"
        ) == nil)
        let rebuilt = try await waitForProjection(
            viewModel: viewModel,
            sessionKey: sessionKey,
            query: "message 19"
        )
        #expect(rebuilt.containsTranscriptMessage(id: "m-0"))
    }

    @Test("T1738: authoritative removal publishes exact IDs once")
    @MainActor
    func authoritativeRemovalPublishesExactIDs() {
        let viewModel = makeViewModel()
        defer { viewModel.prepareForReplacement() }
        let sessionKey = "agent:main:clawline:user:t1738-removal"
        viewModel.debugUpsertMessage(makeMessage(index: 1, sessionKey: sessionKey), isServer: true)
        viewModel.debugUpsertMessage(makeMessage(index: 2, sessionKey: sessionKey), isServer: true)
        var observed: [(String, Set<String>)] = []
        let token = viewModel.registerMessageRemovalObserver { observed.append(($0, $1)) }
        defer { viewModel.unregisterMessageRemovalObserver(token) }

        viewModel.debugClearSessionMessages(sessionKey)

        #expect(observed.count == 1)
        #expect(observed.first?.0 == sessionKey)
        #expect(observed.first?.1 == Set(["m-1", "m-2"]))
    }

    @Test("T1738: 5000-message controller and layout fan-out stay bounded")
    @MainActor
    func controllerLayoutFanOutIsActuallyBounded() async {
        let viewModel = makeViewModel()
        defer { viewModel.prepareForReplacement() }
        let sessionKey = "agent:main:main"
        for index in 0 ..< 5_000 {
            viewModel.debugUpsertMessage(makeMessage(index: index, sessionKey: sessionKey), isServer: true)
        }
        let controller = MessageFlowCollectionViewController()
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 430, height: 900)
        controller.update(
            viewModel: viewModel,
            isCompact: true,
            isActiveSession: true,
            isRenderPolicyFrozen: false,
            isInputActive: false,
            keepsKeyboardPinned: false,
            isTypingActive: false,
            topInset: 0,
            truncationBottomInset: 0,
            firstUnreadMessageId: nil,
            unreadCount: 0,
            sessionKey: sessionKey
        )
        await Task.yield()
        controller.view.layoutIfNeeded()
        controller.debugInsertWebBubbleItems((0 ..< 50).map { index in
            WebBubbleItem(
                id: "web_\(index)",
                createdAt: Date(timeIntervalSince1970: TimeInterval(10_000 + index)),
                stream: .personal,
                parentItemId: "m-\(4_950 + index)",
                initialURL: nil,
                isPopup: true,
                title: nil
            )
        })
        await Task.yield()
        controller.view.layoutIfNeeded()
        let probe = controller.debugBoundedMaterializationProbe()
        let maximum = MessageFlowCollectionViewController.maximumBoundedSnapshotItemCount(
            messageWindowCount: MessageFlowCollectionViewController.stagedMaterializationTailWindowCount
        )

        #expect(probe.snapshotItemCount <= maximum)
        #expect(probe.sizeQueryCount <= maximum)
        #expect(probe.snapshotItemCount >= MessageFlowCollectionViewController.stagedMaterializationTailWindowCount * 2)
    }

    @Test("T1738: true removals invalidate only their session and expire callbacks")
    @MainActor
    func authoritativeRemovalInvalidatesExactSessionAndExpiresCallbacks() async {
        let viewModel = makeViewModel()
        defer { viewModel.prepareForReplacement() }
        let activeSessionKey = "agent:main:clawline:user:t1738-removal-active"
        let inactiveSessionKey = "agent:main:clawline:user:t1738-removal-inactive"
        for index in 0 ..< 100 {
            viewModel.debugUpsertMessage(makeMessage(index: index, sessionKey: activeSessionKey), isServer: true)
            viewModel.debugUpsertMessage(makeMessage(index: index, sessionKey: inactiveSessionKey), isServer: true)
        }
        let controller = MessageFlowCollectionViewController()
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 430, height: 900)
        update(controller, with: viewModel, sessionKey: activeSessionKey)
        await Task.yield()

        var firedCallbacks = 0
        controller.debugSeedAuthoritativeRemovalState(
            sessionKey: activeSessionKey,
            messageId: "m-0",
            callback: { firedCallbacks += 1 }
        )
        controller.debugSeedAuthoritativeRemovalState(
            sessionKey: inactiveSessionKey,
            messageId: "m-0",
            callback: { firedCallbacks += 1 }
        )

        viewModel.debugClearSessionMessages(inactiveSessionKey)
        #expect(!controller.debugAuthoritativeRemovalState(
            sessionKey: inactiveSessionKey,
            messageId: "m-0"
        ).hasSize)
        #expect(controller.debugAuthoritativeRemovalState(
            sessionKey: inactiveSessionKey,
            messageId: "m-0"
        ).callbackCount == 0)
        #expect(controller.debugAuthoritativeRemovalState(
            sessionKey: activeSessionKey,
            messageId: "m-0"
        ).hasSize)
        #expect(controller.debugAuthoritativeRemovalState(
            sessionKey: activeSessionKey,
            messageId: "m-0"
        ).callbackCount == 1)

        viewModel.debugClearSessionMessages(activeSessionKey)
        #expect(!controller.debugAuthoritativeRemovalState(
            sessionKey: activeSessionKey,
            messageId: "m-0"
        ).hasSize)
        #expect(controller.debugAuthoritativeRemovalState(
            sessionKey: activeSessionKey,
            messageId: "m-0"
        ).callbackCount == 0)
        #expect(firedCallbacks == 0)
    }

    @Test("T1738: live web selection includes parentless and is globally newest first")
    @MainActor
    func liveWebSelectionIsBoundedAndGloballyOrdered() {
        let coordinator = WebBubbleCoordinator()
        for index in 0 ..< 1_000 {
            coordinator.debugInsertItem(WebBubbleItem(
                id: "a-\(index)",
                createdAt: Date(timeIntervalSince1970: TimeInterval(index * 3)),
                stream: .personal,
                parentItemId: "parent-a",
                initialURL: nil,
                isPopup: true,
                title: nil
            ))
        }
        coordinator.debugInsertItem(WebBubbleItem(
            id: "parentless",
            createdAt: Date(timeIntervalSince1970: 3_001),
            stream: .personal,
            parentItemId: nil,
            initialURL: nil,
            isPopup: true,
            title: nil
        ))
        coordinator.debugInsertItem(WebBubbleItem(
            id: "b-newest",
            createdAt: Date(timeIntervalSince1970: 3_002),
            stream: .personal,
            parentItemId: "parent-b",
            initialURL: nil,
            isPopup: true,
            title: nil
        ))

        let selected = coordinator.items(
            for: .personal,
            parentIds: ["parent-a", "parent-b"],
            limit: 3
        )

        #expect(selected.map(\.id) == ["b-newest", "parentless", "a-999"])
        #expect(selected.count == 3)
    }

    @Test("T1738: activation path has no tail-to-full promotion or transcript-wide mapper")
    func sourceSeamRemainsBounded() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Clawline/Views/Chat/MessageFlowCollectionView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        #expect(!source.contains("scheduleTailToFullPromotionIfNeeded"))
        #expect(!source.contains("messagesById = Dictionary(uniqueKeysWithValues: messages.map"))
        #expect(!source.contains("let fullMessageIds = messages.map"))
        #expect(source.contains("projection.messages("))
        #expect(source.contains("snapshot.numberOfItems <= Self.maximumBoundedSnapshotItemCount"))
    }

    private func makeMessages(count: Int) -> [Message] {
        (0 ..< count).map { makeMessage(index: $0) }
    }

    private func makeMessage(index: Int, sessionKey: String = "T1738") -> Message {
        Message(
            id: "m-\(index)",
            role: index.isMultiple(of: 2) ? .user : .assistant,
            content: "message \(index)",
            timestamp: Date(timeIntervalSince1970: TimeInterval(index)),
            streaming: false,
            attachments: [],
            deviceId: nil,
            sessionKey: sessionKey
        )
    }

    @MainActor
    private func update(
        _ controller: MessageFlowCollectionViewController,
        with viewModel: ChatViewModel,
        sessionKey: String
    ) {
        controller.update(
            viewModel: viewModel,
            isCompact: true,
            isActiveSession: true,
            isRenderPolicyFrozen: false,
            isInputActive: false,
            keepsKeyboardPinned: false,
            isTypingActive: false,
            topInset: 0,
            truncationBottomInset: 0,
            firstUnreadMessageId: nil,
            unreadCount: 0,
            sessionKey: sessionKey
        )
    }

    @MainActor
    private func makeViewModel() -> ChatViewModel {
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        return ChatViewModel(
            auth: auth,
            chatService: TestChatService(),
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: T1738UploadService(),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
    }

    @MainActor
    private func waitForProjection(
        viewModel: ChatViewModel,
        sessionKey: String,
        query: String
    ) async throws -> MessageProjectionSnapshot {
        for _ in 0 ..< 100 {
            if let projection = viewModel.messageProjection(
                for: sessionKey,
                showOnlyUserMessages: false,
                searchQuery: query
            ) {
                return projection
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for selected projection")
        return MessageProjectionIndex().snapshot(base: .transcript)
    }
}
