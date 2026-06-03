//
//  Clawline_Watch_Watch_AppTests.swift
//  Clawline Watch Watch AppTests
//
//  Created by Mike Manzano on 1/7/26.
//

import Foundation
import Testing
@testable import Clawline_Watch_Watch_App

struct Clawline_Watch_Watch_AppTests {

    @Test @MainActor func historyPagesKeepNewestMessagesOnFinalPage() async throws {
        let now = Date()
        let entries = (1...7).map { index in
            WatchConversationStore.Entry(
                id: "entry_\(index)",
                role: index.isMultiple(of: 2) ? .assistant : .user,
                content: "Message \(index)",
                timestamp: now.addingTimeInterval(Double(index))
            )
        }

        let pages = WatchMainView.historyPages(from: entries)

        #expect(pages.map { page in page.entries.map { entry in entry.id } } == [
            ["entry_1", "entry_2", "entry_3"],
            ["entry_4", "entry_5", "entry_6"],
            ["entry_7"]
        ])
        #expect(pages.last?.entries.last?.id == "entry_7")
    }

    @Test @MainActor func pagedHistoryKeepsCurrentMessagesWithMicPage() async throws {
        let now = Date()
        let entries = (1...7).map { index in
            WatchConversationStore.Entry(
                id: "entry_\(index)",
                role: index.isMultiple(of: 2) ? .assistant : .user,
                content: "Message \(index)",
                timestamp: now.addingTimeInterval(Double(index))
            )
        }

        let pagedHistory = WatchMainView.pagedHistory(from: entries)

        #expect(pagedHistory.historyPages.map { page in page.entries.map { entry in entry.id } } == [
            ["entry_1", "entry_2", "entry_3"],
            ["entry_4", "entry_5", "entry_6"]
        ])
        #expect(pagedHistory.currentPage?.entries.map { $0.id } == ["entry_7"])
    }

    @Test func watchShellUsesViewportPagingForUnifiedMicSurface() throws {
        let sourcePath = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Clawline Watch Watch App/Views/WatchMainView.swift")
        let source = try String(contentsOf: sourcePath, encoding: .utf8)

        #expect(source.contains(".scrollTargetBehavior(.paging)"))
        #expect(source.contains("currentConversationPage("))
        #expect(source.contains("historyPage("))
        #expect(source.contains("ringControl(ringDiameter: ringDiameter)"))
        #expect(source.contains("Image(systemName: routeIconName)"))
    }

}
