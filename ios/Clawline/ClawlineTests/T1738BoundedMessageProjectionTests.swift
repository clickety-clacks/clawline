import Foundation
import Testing
@testable import Clawline

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

    @Test("T1738: auxiliary snapshot fan-out has a fixed formula")
    func maximumSnapshotCountIsBounded() {
        #expect(MessageFlowCollectionViewController.maximumBoundedSnapshotItemCount(messageWindowCount: 50) == 152)
        #expect(MessageFlowCollectionViewController.maximumBoundedSnapshotItemCount(messageWindowCount: 100) == 302)
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

    private func makeMessage(index: Int) -> Message {
        Message(
            id: "m-\(index)",
            role: index.isMultiple(of: 2) ? .user : .assistant,
            content: "message \(index)",
            timestamp: Date(timeIntervalSince1970: TimeInterval(index)),
            streaming: false,
            attachments: [],
            deviceId: nil,
            sessionKey: "T1738"
        )
    }
}
