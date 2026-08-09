@testable import Clawline
import SwiftUI
import Testing
import UIKit

@MainActor
struct SelectableAttributedTextMeasurementTests {
    @Test("SMP-T1: repeated width uses one real measurement")
    func repeatedWidthUsesOneMeasurement() {
        let coordinator = makeCoordinator()
        let textView = makeTextView("Repeated selectable Markdown measurement")

        let first = coordinator.measuredSize(width: 240, using: textView)
        let second = coordinator.measuredSize(width: 240, using: textView)

        #expect(first == second)
        #expect(coordinator.measurementMissCount == 1)
    }

    @Test("SMP-T2: memoized results preserve the pre-change sizing formula")
    func memoizedResultsMatchFreshMeasurements() {
        let corpus = "Measurement cost scales with laid-out text across several wrapped lines and widths."
        let textView = makeTextView(corpus)
        let coordinator = makeCoordinator()

        for width: CGFloat in [120, 180, 260, 360] {
            let freshTextView = makeTextView(corpus)
            let fitting = freshTextView.sizeThatFits(
                CGSize(width: width, height: .greatestFiniteMagnitude)
            )
            let expected = CGSize(width: width, height: ceil(fitting.height))

            #expect(coordinator.measuredSize(width: width, using: textView) == expected)
            #expect(coordinator.measuredSize(width: width, using: textView) == expected)
        }
    }

    @Test("SMP-T3: content replacement clears while stable table output preserves")
    func contentInvalidationAndStableTableIdentity() throws {
        let coordinator = makeCoordinator()
        let textView = makeTextView("First")
        coordinator.update(
            view: textView,
            attributedString: NSAttributedString(string: "First"),
            alignment: .left,
            userInterfaceStyle: .light,
            selectionResetToken: 0
        )
        _ = coordinator.measuredSize(width: 220, using: textView)
        let initialMisses = coordinator.measurementMissCount

        coordinator.update(
            view: textView,
            attributedString: NSAttributedString(string: "A genuinely different value"),
            alignment: .left,
            userInterfaceStyle: .light,
            selectionResetToken: 0
        )
        _ = coordinator.measuredSize(width: 220, using: textView)
        #expect(coordinator.measurementMissCount == initialMisses + 1)

        let mutableSource = NSMutableAttributedString(string: "Mutable source")
        coordinator.update(
            view: textView,
            attributedString: mutableSource,
            alignment: .left,
            userInterfaceStyle: .light,
            selectionResetToken: 0
        )
        _ = coordinator.measuredSize(width: 220, using: textView)
        let snapshotBeforeMutation = try #require(coordinator.lastSubmittedAttributedString)
        let missesBeforeMutation = coordinator.measurementMissCount
        mutableSource.append(NSAttributedString(string: " changed"))
        #expect(snapshotBeforeMutation.string == "Mutable source")
        #expect(coordinator.lastSubmittedAttributedString?.string == "Mutable source")
        #expect(snapshotBeforeMutation !== mutableSource)

        coordinator.update(
            view: textView,
            attributedString: mutableSource,
            alignment: .left,
            userInterfaceStyle: .light,
            selectionResetToken: 0
        )
        _ = coordinator.measuredSize(width: 220, using: textView)
        #expect(coordinator.measurementMissCount == missesBeforeMutation + 1)
        let snapshotAfterMutation = try #require(coordinator.lastSubmittedAttributedString)
        #expect(snapshotAfterMutation.string == "Mutable source changed")
        #expect(snapshotAfterMutation !== mutableSource)

        let cell = try makeCell("Stable `code` cell")
        let firstTable = makeTable()
        let secondTable = makeTable()
        let first = firstTable.styledAttributedString(for: cell, alignment: .leading, isHeader: false)
        let second = secondTable.styledAttributedString(for: cell, alignment: .leading, isHeader: false)
        #expect(first.isEqual(to: second))
        #expect(SelectableAttributedText.needsAttributedTextUpdate(current: first, next: second) == false)
        coordinator.update(
            view: textView,
            attributedString: first,
            alignment: .left,
            userInterfaceStyle: .light,
            selectionResetToken: 0
        )
        #expect(!textView.attributedText.isEqual(to: first))
        _ = coordinator.measuredSize(width: 220, using: textView)
        let stableMisses = coordinator.measurementMissCount

        coordinator.update(
            view: textView,
            attributedString: second,
            alignment: .left,
            userInterfaceStyle: .light,
            selectionResetToken: 0
        )
        _ = coordinator.measuredSize(width: 220, using: textView)
        #expect(coordinator.measurementMissCount == stableMisses)
    }

    @Test("SMP-T4: alignment clears; appearance and selection reset do not")
    func invalidationNegativeCases() {
        let coordinator = makeCoordinator()
        let textView = makeTextView("Selection and appearance")
        let attributed = NSAttributedString(attributedString: textView.attributedText)
        coordinator.update(
            view: textView,
            attributedString: attributed,
            alignment: .left,
            userInterfaceStyle: .light,
            selectionResetToken: 0
        )
        _ = coordinator.measuredSize(width: 210, using: textView)
        let missesBeforeAlignment = coordinator.measurementMissCount

        coordinator.update(
            view: textView,
            attributedString: attributed,
            alignment: .center,
            userInterfaceStyle: .light,
            selectionResetToken: 0
        )
        _ = coordinator.measuredSize(width: 210, using: textView)
        let missesAfterAlignment = coordinator.measurementMissCount
        #expect(missesAfterAlignment == missesBeforeAlignment + 1)

        textView.selectedRange = NSRange(location: 0, length: 3)
        coordinator.update(
            view: textView,
            attributedString: attributed,
            alignment: .center,
            userInterfaceStyle: .dark,
            selectionResetToken: 1
        )
        textView.refreshAttributedTextForCurrentTraits()
        _ = coordinator.measuredSize(width: 210, using: textView)

        #expect(textView.selectedRange.length == 0)
        #expect(coordinator.measurementMissCount == missesAfterAlignment)
    }

    @Test("SMP-T5: Dynamic Type trait change invalidates hosted measurement")
    func dynamicTypeTraitChangeInvalidatesHostedMeasurement() async throws {
        guard let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first
        else {
            Issue.record("No UIWindowScene available for Dynamic Type trait test")
            return
        }

        let coordinator = makeCoordinator()
        let textView = makeTextView("Dynamic Type measurement wraps across multiple lines at this width.")
        textView.adjustsFontForContentSizeCategory = true
        textView.onTextMetricsTraitChange = coordinator.invalidateMeasurementMemo

        let host = UIViewController()
        textView.frame = CGRect(x: 0, y: 0, width: 160, height: 300)
        host.view.addSubview(textView)
        let window = UIWindow(windowScene: windowScene)
        window.frame = CGRect(x: 0, y: 0, width: 180, height: 320)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.traitOverrides.preferredContentSizeCategory = .large
        host.view.layoutIfNeeded()
        await drainMainQueue()
        #expect(textView.traitCollection.preferredContentSizeCategory == .large)

        let initialSize = coordinator.measuredSize(width: 160, using: textView)
        let initialFont = try #require(textView.attributedText.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        let initialMisses = coordinator.measurementMissCount
        host.view.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
        host.view.layoutIfNeeded()
        await drainMainQueue()
        #expect(textView.traitCollection.preferredContentSizeCategory == .accessibilityExtraExtraExtraLarge)
        let changedSize = coordinator.measuredSize(width: 160, using: textView)
        let changedFont = try #require(textView.attributedText.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)

        #expect(coordinator.measurementMissCount == initialMisses + 1)
        #expect(changedFont.pointSize > initialFont.pointSize)
        #expect(changedSize.height > initialSize.height)

        let missesBeforeLegibilityChange = coordinator.measurementMissCount
        host.view.traitOverrides.legibilityWeight = .bold
        host.view.layoutIfNeeded()
        await drainMainQueue()
        #expect(textView.traitCollection.legibilityWeight == .bold)
        _ = coordinator.measuredSize(width: 160, using: textView)
        #expect(coordinator.measurementMissCount == missesBeforeLegibilityChange + 1)
        window.isHidden = true
    }

    @Test("SMP-T6: ninth distinct width clears the bounded memo")
    func memoNeverExceedsEightWidths() {
        let coordinator = makeCoordinator()
        let textView = makeTextView("Bounded width memo")

        for width in (1 ... 9).map({ CGFloat($0 * 40) }) {
            let fitting = textView.sizeThatFits(
                CGSize(width: width, height: .greatestFiniteMagnitude)
            )
            let expected = CGSize(width: width, height: ceil(fitting.height))
            #expect(coordinator.measuredSize(width: width, using: textView) == expected)
            #expect(coordinator.measurementMemoEntryCount <= 8)
        }

        #expect(coordinator.measurementMemoEntryCount == 1)
    }

    @Test("SMP-T7: table attributed-string colors keep stable identity and values")
    func tableColorsAreStableAndTraitCorrect() throws {
        let cell = try makeCell("Value with `code`")
        let firstTable = makeTable()
        let secondTable = makeTable()
        let first = firstTable.styledAttributedString(for: cell, alignment: .leading, isHeader: false)
        let second = secondTable.styledAttributedString(for: cell, alignment: .leading, isHeader: false)

        #expect(first.isEqual(to: second))
        #expect(SelectableAttributedText.needsAttributedTextUpdate(current: first, next: second) == false)

        let fullRange = NSRange(location: 0, length: first.length)
        let foreground = try #require(first.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor)
        let codeRange = (first.string as NSString).range(of: "code")
        let background = try #require(first.attribute(.backgroundColor, at: codeRange.location, effectiveRange: nil) as? UIColor)
        let bodyFont = try #require(first.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        let codeFont = try #require(first.attribute(.font, at: codeRange.location, effectiveRange: nil) as? UIFont)
        let paragraph = try #require(first.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        let header = firstTable.styledAttributedString(for: cell, alignment: .leading, isHeader: true)
        let headerFont = try #require(header.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        #expect(fullRange.length > 0)
        #expect(first.attribute(.inlinePresentationIntent, at: codeRange.location, effectiveRange: nil) != nil)
        #expect(bodyFont == UIFont.clawline(.bodyText))
        #expect(codeFont == UIFont.clawlineMonospaced(.secondaryLabel))
        #expect(headerFont == UIFont.clawline(.mediumMessage))
        #expect(paragraph.alignment == .left)
        #expect(paragraph.lineBreakMode == .byWordWrapping)

        let lightTraits = UITraitCollection(userInterfaceStyle: .light)
        let darkTraits = UITraitCollection(userInterfaceStyle: .dark)
        #expect(foreground.resolvedColor(with: lightTraits).isEqual(UIColor(ChatFlowTheme.ink(.light))))
        #expect(foreground.resolvedColor(with: darkTraits).isEqual(UIColor(red: 0.941, green: 0.918, blue: 0.894, alpha: 1)))
        #expect(background.resolvedColor(with: lightTraits).isEqual(UIColor.black.withAlphaComponent(0.08)))
        #expect(background.resolvedColor(with: darkTraits).isEqual(UIColor.white.withAlphaComponent(0.12)))
    }

    private func makeCoordinator() -> SelectableAttributedText.Coordinator {
        SelectableAttributedText.Coordinator(onSelectionChange: { _ in }, onLinkTap: { _ in })
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }

    private func makeTextView(_ value: String) -> SelectableAttributedText.TraitResponsiveTextView {
        let textView = SelectableAttributedText.TraitResponsiveTextView()
        UnifiedMarkdownRenderer.configureTextView(
            textView,
            delegate: nil,
            enableDataDetectors: false
        )
        textView.textContainer.widthTracksTextView = true
        textView.attributedText = NSAttributedString(
            string: value,
            attributes: [.font: UIFont.clawline(.bodyText)]
        )
        return textView
    }

    private func makeCell(_ markdown: String) throws -> TableModel.Cell {
        let attributed = try AttributedString(markdown: markdown)
        return TableModel.Cell(
            attributed: attributed,
            intrinsicWidth: 80,
            plainText: String(attributed.characters),
            isEmpty: false
        )
    }

    private func makeTable() -> MarkdownTableView {
        MarkdownTableView(
            model: TableModel(
                columns: [TableModel.Column(alignment: .leading)],
                header: nil,
                rows: [],
                messageID: "smp-table",
                rowOffset: 0
            ),
            role: .assistant,
            metrics: ChatFlowTheme.Metrics(isCompact: true),
            maxLineWidth: 420,
            isExpanded: false,
            onExpand: {},
            onCollapse: {}
        )
    }
}
