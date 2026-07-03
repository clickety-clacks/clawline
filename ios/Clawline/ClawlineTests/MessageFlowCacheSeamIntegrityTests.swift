import Foundation
import Testing

struct MessageFlowCacheSeamIntegrityTests {
    @Test("T085: direct cache mutations stay inside cache seam block")
    func directCacheMutationsAreScopedToSeam() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ClawlineTests
            .deletingLastPathComponent() // Clawline
            .appendingPathComponent("Clawline/Views/Chat/MessageFlowCollectionView.swift")
        let contents = try String(contentsOf: sourceURL, encoding: .utf8)
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        guard let seamStart = lines.firstIndex(where: { $0.contains("// MARK: - Cache Mutation Seam") }),
              let seamEnd = lines.firstIndex(where: { $0.contains("override func viewDidLayoutSubviews()") }) else {
            Issue.record("Unable to locate cache seam boundaries in MessageFlowCollectionView.swift")
            return
        }

        // Mutation-only patterns from the spec's acceptance criterion #7 + dirty-size invalidation writes.
        let patterns: [String] = [
            "sizeCache\\[.*\\]\\s*=",
            "sizeCache\\.remove",
            "lastMeasuredSizes\\[.*\\]\\s*=",
            "lastMeasuredSizes\\.remove",
            "bubbleSizingV2MeasurementCache\\.setValue",
            "bubbleSizingV2MeasurementCache\\.remove",
            "bubbleSizingV2LayoutStateCache\\.setValue",
            "bubbleSizingV2LayoutStateCache\\.remove",
            "bubbleSizingV2KeysByMessageId\\[.*\\]",
            "bubbleSizingV2KeysByMessageId\\.remove",
            "bubbleSizingV2LinkPreviewHeightCache\\.set",
            "bubbleSizingV2LinkPreviewStateVersionByMessageId\\[.*\\]",
            "bubbleSizingV2LinkPreviewStateVersionByMessageId\\.remove",
            "dirtySizeIds\\.insert",
            "dirtySizeIds\\.remove"
        ]
        let regexes = try patterns.map { pattern in
            try NSRegularExpression(pattern: pattern)
        }

        for (idx, line) in lines.enumerated() {
            let lineNumber = idx + 1
            let isInsideSeam = idx >= seamStart && idx < seamEnd
            let range = NSRange(location: 0, length: (line as NSString).length)
            for (pattern, regex) in zip(patterns, regexes) {
                if regex.firstMatch(in: line, range: range) != nil {
                    #expect(isInsideSeam, "Direct cache mutation pattern '\(pattern)' escaped seam at line \(lineNumber)")
                }
            }
        }
    }

    @Test("T138: date separators use full available row width")
    func dateSeparatorsUseAvailableContentWidth() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ClawlineTests
            .deletingLastPathComponent() // Clawline
            .appendingPathComponent("Clawline/Views/Chat/MessageFlowCollectionView.swift")
        let contents = try String(contentsOf: sourceURL, encoding: .utf8)
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        guard let sizeForItemStart = lines.firstIndex(where: { $0.contains("private func sizeForItem(at indexPath: IndexPath)") }),
              let sizeForItemEnd = lines[sizeForItemStart...]
                .firstIndex(where: { $0.contains("// Handle typing indicator size") }),
              let branchStart = lines[sizeForItemStart..<sizeForItemEnd]
                .firstIndex(where: { $0.contains("if DateSeparatorCell.isDateSeparatorItemID(id)") }) else {
            Issue.record("Unable to locate date separator sizing branch inside sizeForItem(at:).")
            return
        }

        let windowEnd = min(lines.count, branchStart + 12)
        let branchWindow = lines[branchStart..<windowEnd]

        #expect(
            branchWindow.contains(where: { $0.contains("let rowWidth = availableContentWidth()") }),
            "Date separator width should use availableContentWidth() so separators remain full-row dividers."
        )
        #expect(
            !branchWindow.contains(where: { $0.contains("effectiveContentWidth(metrics: metrics)") }),
            "Date separator width must not use bubble-capped effectiveContentWidth()."
        )
    }

    @Test("T138: full-row items force their own layout row")
    func fullRowItemsForceDedicatedLayoutRow() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ClawlineTests
            .deletingLastPathComponent() // Clawline
            .appendingPathComponent("Clawline/Views/Chat/MessageFlowCollectionView.swift")
        let contents = try String(contentsOf: sourceURL, encoding: .utf8)

        #expect(
            contents.contains("if fullRowItem, x > sectionInset.left {"),
            "Full-row items should flush the current row before layout so date separators cannot render inline."
        )
        #expect(
            contents.contains("if fullRowItem {\n                x = sectionInset.left\n                y = frame.maxY"),
            "Full-row items should advance layout to the next row after placement."
        )
        #expect(
            contents.contains("if MessageFlowRowLayoutEngine.isFullRowItem(width: size.width, contentWidth: signature.contentWidth, sectionInset: sectionInset) ||\n            MessageFlowRowLayoutEngine.isFullRowItem(width: previousAttributes.frame.width, contentWidth: signature.contentWidth, sectionInset: sectionInset) {"),
            "Incremental append should fall back to a rebuild when a full-row item is involved."
        )
    }

    @Test("T1484: message rows use compact inter-bubble spacing")
    func messageRowsUseCompactInterBubbleSpacing() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ClawlineTests
            .deletingLastPathComponent() // Clawline
            .appendingPathComponent("Clawline/Views/Chat/MessageFlowCollectionView.swift")
        let contents = try String(contentsOf: sourceURL, encoding: .utf8)

        #expect(
            contents.contains("flowLayout.minimumLineSpacing = metrics.flowGap"),
            "Default row spacing should remain the broader flow gap for date separators, footer/search, web, and typing rows."
        )
        #expect(
            contents.contains("flowLayout.rowSpacingProvider = { [weak self] previousIndex, nextIndex in"),
            "Message flow layout should support pair-specific row spacing."
        )
        #expect(
            contents.contains("flowLayout.rowSpacingFingerprintProvider = { [weak self] in"),
            "Pair-specific spacing must participate in the layout cache signature."
        )
        #expect(
            contents.contains("let size = (collectionView.delegate as? UICollectionViewDelegateFlowLayout)?\n                .collectionView?(collectionView, layout: self, sizeForItemAt: indexPath) ?? itemSize\n            layoutItems.append(MessageFlowRowLayoutEngine.Item(index: item, size: size))"),
            "Full row composition must use delegate sizeForItem output, not a stale or partial cell frame."
        )
        #expect(
            contents.contains("guard isNormalMessageItem(at: previousIndex),\n              isNormalMessageItem(at: nextIndex) else"),
            "Only normal message-to-message adjacency should use compact T1484 spacing."
        )
        #expect(
            contents.contains("let rowSpacingFingerprint: Int"),
            "Layout signature should change when row-spacing-relevant item identity changes."
        )
        #expect(
            contents.contains("rowMinY + rowHeight + rowSpacing(afterItem: previousIndexPath.item, beforeItem: newItemIndex)"),
            "Incremental append wrapping should use the same pair-specific row spacing as full layout rebuilds."
        )
        #expect(
            contents.contains("MessageBubbleGeometry.adjacentMessageRowSpacing(metrics: metrics)"),
            "T1485 proof: compact row gap comes from the shared bubble geometry invariant."
        )
    }

    @Test("T1465: row flow keeps ordinary bubbles content-shaped")
    func rowFlowKeepsOrdinaryBubblesContentShaped() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ClawlineTests
            .deletingLastPathComponent() // Clawline
            .appendingPathComponent("Clawline/Views/Chat")
        let flowContents = try String(
            contentsOf: sourceRoot.appendingPathComponent("MessageFlowCollectionView.swift"),
            encoding: .utf8
        )
        let bubbleContents = try String(
            contentsOf: sourceRoot.appendingPathComponent("MessageBubbleUIKitView.swift"),
            encoding: .utf8
        )

        #expect(
            flowContents.contains("case .medium:\n                return 80"),
            "Medium bubbles must not use a percentage-of-row minimum width; flow packing owns row capacity."
        )
        #expect(
            !flowContents.contains("env.containerWidth * 0.25"),
            "Ordinary bubble width floors must not be derived from row width."
        )
        #expect(
            !flowContents.contains("itemForcesOwnRowProvider"),
            "Normal bubbles must not bypass flow packing through a row-forcing hook."
        )
        #expect(
            bubbleContents.contains("override var intrinsicContentSize: CGSize {\n        super.intrinsicContentSize\n    }"),
            "BubbleTextView should report UIKit's fitted size instead of a separate TextKit usedRect authority."
        )
        #expect(
            !bubbleContents.contains("tightFittingSize(for:"),
            "Bubble text sizing must not reintroduce a second fitting authority."
        )
    }

    @Test("T1193: V2 sizing and visible cells consume one authoritative layout state")
    func bubbleSizingV2SizingAndRenderingShareAuthoritativeLayoutState() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ClawlineTests
            .deletingLastPathComponent() // Clawline
            .appendingPathComponent("Clawline/Views/Chat/MessageFlowCollectionView.swift")
        let contents = try String(contentsOf: sourceURL, encoding: .utf8)
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        guard let sizeForItemStart = lines.firstIndex(where: { $0.contains("private func sizeForItem(at indexPath: IndexPath)") }),
              let sizeForItemEnd = lines[sizeForItemStart...].firstIndex(where: { $0.contains("private func measureUIKitBubbleSize") }),
              let cellProviderStart = lines.firstIndex(where: { $0.contains("withReuseIdentifier: MessageBubbleUIKitCell.reuseIdentifier") }),
              let cellProviderEnd = lines[cellProviderStart...].firstIndex(where: { $0.contains("cell?.configure(") }),
              let authorityStart = lines.firstIndex(where: { $0.contains("private func authoritativeBubbleSizingV2LayoutState") }),
              let authorityEnd = lines[authorityStart...].firstIndex(where: { $0.contains("private func bubbleSizingV2LayoutState(") }) else {
            Issue.record("Unable to locate the V2 sizing, visible rendering, or authoritative geometry sections.")
            return
        }

        let sizeForItemWindow = lines[sizeForItemStart..<sizeForItemEnd].joined(separator: "\n")
        let cellProviderWindow = lines[cellProviderStart..<cellProviderEnd].joined(separator: "\n")
        let authorityWindow = lines[authorityStart..<authorityEnd].joined(separator: "\n")

        #expect(
            sizeForItemWindow.contains("authoritativeBubbleSizingV2LayoutState("),
            "sizeForItem must resolve the shared authoritative V2 layout state instead of independently producing a plan."
        )
        #expect(
            cellProviderWindow.contains("authoritativeBubbleSizingV2LayoutState("),
            "Visible cells must consume the same authoritative V2 layout state used by first-pass sizing."
        )
        #expect(
            !cellProviderWindow.contains("bubbleSizingV2Plan("),
            "Visible cells must not run a second V2 planning algorithm and silently self-heal after scroll."
        )
        #expect(
            authorityWindow.contains("bubbleSizingV2Plan(") && authorityWindow.contains("bubbleSizingV2LayoutState("),
            "The geometry authority should be the only place that joins plan resolution with measured/render layout state."
        )
        #expect(
            contents.contains("private let bubbleSizingV2LayoutStateCache"),
            "The shared authority must cache the complete LayoutState, not only a size, so rendering consumes the measured plan."
        )
    }
}
