//
//  T117DateSeparatorDynamicTypeTests.swift
//  ClawlineTests
//

import Testing
import UIKit
@testable import Clawline

@MainActor
struct T117DateSeparatorDynamicTypeTests {
    @Test("T117: date separator uses centered caption role")
    func dateSeparatorCellUsesCenteredCaptionRole() throws {
        let cell = DateSeparatorCell(frame: CGRect(x: 0, y: 0, width: 320, height: 64))
        cell.configure(text: "Today", isDark: false)

        let label = try #require(cell.contentView.subviews.compactMap { $0 as? UILabel }.first)
        #expect(label.text == "Today")
        #expect(label.textAlignment == .center)
        #expect(label.adjustsFontForContentSizeCategory)
        #expect(label.font.fontName == DateSeparatorCell.separatorFont.fontName)
        #expect(label.font.pointSize == DateSeparatorCell.separatorFont.pointSize)
    }

    @Test("T117: date separator role scales distinctly from ui label")
    func dateSeparatorRoleScalesAsCaption() {
        let dateSeparatorFont = DateSeparatorCell.separatorFont
        let uiLabelFont = UIFont.clawline(.uiLabel, weight: .semibold)
        let senderNameFont = UIFont.clawline(.senderName)

        #expect(dateSeparatorFont.pointSize < uiLabelFont.pointSize)
        #expect(dateSeparatorFont.pointSize == senderNameFont.pointSize)
    }

    @Test("T117: date separator sizing uses the same role and balanced padding")
    func dateSeparatorSizingUsesRoleAndBalancedPadding() {
        #expect(DateSeparatorCell.topPadding == 16)
        #expect(DateSeparatorCell.bottomPadding == 16)
        #expect(DateSeparatorCell.separatorHeight == ceil(DateSeparatorCell.separatorFont.lineHeight + 32))
    }
}
