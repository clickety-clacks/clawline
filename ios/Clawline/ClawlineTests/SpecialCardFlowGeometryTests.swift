import UIKit
import Testing
@testable import Clawline

struct SpecialCardFlowGeometryTests {
    @Test("special presentations use the ordinary compact and regular card-flow bounds")
    @MainActor
    func sharedCardFlowWidthIsBoundedAtSupportedSizes() {
        let compact = MessageFlowCollectionViewController.boundedCardFlowWidth(
            availableWidth: 366,
            containerPadding: 12
        )
        let regular = MessageFlowCollectionViewController.boundedCardFlowWidth(
            availableWidth: 976,
            containerPadding: 24
        )

        #expect(compact == 366)
        #expect(regular == 696)
        #expect(regular < 976)
    }

    @Test("a bounded special presentation participates in ordinary row placement")
    @MainActor
    func boundedPresentationUsesOrdinaryRowLayout() {
        let sectionInset = UIEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        let cardFlowWidth = MessageFlowCollectionViewController.boundedCardFlowWidth(
            availableWidth: 976,
            containerPadding: 24
        )
        let result = MessageFlowRowLayoutEngine.layout(
            items: [
                .init(index: 0, size: CGSize(width: cardFlowWidth, height: 44)),
                .init(index: 1, size: CGSize(width: 200, height: 52))
            ],
            contentWidth: 1024,
            sectionInset: sectionInset,
            minimumInteritemSpacing: 16,
            rowSpacing: { _, _ in 24 }
        )
        let frames = Dictionary(uniqueKeysWithValues: result.items.map { ($0.index, $0.frame) })

        #expect(MessageFlowRowLayoutEngine.isFullRowItem(
            width: cardFlowWidth,
            contentWidth: 1024,
            sectionInset: sectionInset
        ) == false)
        #expect(frames[0]?.minY == frames[1]?.minY)
        #expect(frames[1]?.minX == 24 + cardFlowWidth + 16)
    }

    @Test("ordinary messages and every special presentation share card-flow identity")
    @MainActor
    func allSpecialPresentationsParticipateInCardFlow() {
        #expect(MessageFlowCollectionViewController.participatesInCardFlow(
            id: "message-1",
            isMessage: true
        ))
        #expect(MessageFlowCollectionViewController.participatesInCardFlow(
            id: "__substrate_run__|message-2",
            isMessage: false
        ))
        #expect(MessageFlowCollectionViewController.participatesInCardFlow(
            id: MarkerDividerCell.itemID(before: "message-3"),
            isMessage: false
        ))
        #expect(!MessageFlowCollectionViewController.participatesInCardFlow(
            id: SessionMetadataFooterCell.itemId,
            isMessage: false
        ))
    }

    @Test("the bottom scroll anchor includes collapsed substrate runs and markers")
    @MainActor
    func lastCardFlowItemDrivesScrollPlacement() {
        let collapsedRun = "__substrate_run__|message-2"
        let marker = MarkerDividerCell.itemID(before: "message-3")
        let ids = ["message-1", collapsedRun, marker, SessionMetadataFooterCell.itemId]

        let last = MessageFlowCollectionViewController.lastCardFlowItemID(
            in: ids,
            isMessage: { $0 == "message-1" }
        )
        #expect(last == marker)

        let withoutMarker = MessageFlowCollectionViewController.lastCardFlowItemID(
            in: ["message-1", collapsedRun, SessionMetadataFooterCell.itemId],
            isMessage: { $0 == "message-1" }
        )
        #expect(withoutMarker == collapsedRun)
    }

    @Test("substrate text wraps at compact width and scales with Dynamic Type")
    @MainActor
    func substrateGeometryWrapsAndScales() {
        let content = String(repeating: "bounded substrate notice wraps naturally ", count: 12)
        let regularTraits = UITraitCollection(preferredContentSizeCategory: .large)
        let accessibilityTraits = UITraitCollection(
            preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge
        )
        let compact = SubstrateRowCell.measuredHeight(
            header: .tightbeam,
            detail: content,
            rowWidth: 320,
            isIndentedUnderRun: false,
            compatibleWith: regularTraits
        )
        let regular = SubstrateRowCell.measuredHeight(
            header: .tightbeam,
            detail: content,
            rowWidth: 696,
            isIndentedUnderRun: false,
            compatibleWith: regularTraits
        )
        let accessibility = SubstrateRowCell.measuredHeight(
            header: .tightbeam,
            detail: content,
            rowWidth: 696,
            isIndentedUnderRun: false,
            compatibleWith: accessibilityTraits
        )

        #expect(compact > regular)
        #expect(accessibility > regular)
    }

    @Test("collapsed substrate and marker rows honor Dynamic Type")
    @MainActor
    func compactSpecialRowsScaleWithDynamicType() {
        let regularTraits = UITraitCollection(preferredContentSizeCategory: .large)
        let accessibilityTraits = UITraitCollection(
            preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge
        )

        #expect(
            SubstrateRunCollapseCell.measuredHeight(compatibleWith: accessibilityTraits)
                > SubstrateRunCollapseCell.measuredHeight(compatibleWith: regularTraits)
        )
        #expect(
            MarkerDividerCell.measuredHeight(compatibleWith: accessibilityTraits)
                > MarkerDividerCell.measuredHeight(compatibleWith: regularTraits)
        )
    }
}
