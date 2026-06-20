//
//  ChatDateLabelCalendarTests.swift
//  ClawlineTests
//
//  Created by Codex on 6/19/26.
//

import Foundation
import Testing
@testable import Clawline

struct ChatDateLabelCalendarTests {
    @Test("T1362: adjacent near-midnight UTC messages stay in one local day bucket")
    func adjacentNearMidnightUTCMessagesStayInOneLocalDayBucket() throws {
        let calendar = try pacificCalendar()
        let messageTimes = [
            Date(timeIntervalSince1970: 1_781_927_560.043),
            Date(timeIntervalSince1970: 1_781_927_745.217),
            Date(timeIntervalSince1970: 1_781_927_857.713)
        ]

        let dayStarts = messageTimes.map { ChatDateLabelCalendar.startOfDay(for: $0, calendar: calendar) }

        #expect(Set(dayStarts).count == 1)
        #expect(calendar.component(.day, from: dayStarts[0]) == 19)
    }

    @Test("T1362: Today and Yesterday decisions use the same local calendar basis")
    func todayYesterdayDecisionsUseLocalCalendarBasis() throws {
        let calendar = try pacificCalendar()
        let eveningPDT = Date(timeIntervalSince1970: 1_781_927_745.217)
        let laterSameEveningPDT = try #require(
            calendar.date(from: DateComponents(year: 2026, month: 6, day: 19, hour: 21, minute: 5))
        )
        let afterLocalMidnight = try #require(
            calendar.date(from: DateComponents(year: 2026, month: 6, day: 20, hour: 0, minute: 5))
        )

        #expect(ChatDateLabelCalendar.isSameDay(eveningPDT, laterSameEveningPDT, calendar: calendar))
        #expect(!ChatDateLabelCalendar.isYesterday(eveningPDT, now: laterSameEveningPDT, calendar: calendar))
        #expect(!ChatDateLabelCalendar.isSameDay(eveningPDT, afterLocalMidnight, calendar: calendar))
        #expect(ChatDateLabelCalendar.isYesterday(eveningPDT, now: afterLocalMidnight, calendar: calendar))
    }

    private func pacificCalendar() throws -> Calendar {
        let timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }
}
