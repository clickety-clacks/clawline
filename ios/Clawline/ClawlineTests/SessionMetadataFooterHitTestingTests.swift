import Testing
import UIKit
@testable import Clawline

@MainActor
struct SessionMetadataFooterHitTestingTests {
    @Test("Footer action regions are stable non-overlapping tap targets")
    func footerActionRegionsAreStableNonOverlappingTapTargets() throws {
        let cell = makeConfiguredCell()
        let buttons = try footerButtons(in: cell)

        for button in buttons {
            let frame = button.convert(button.bounds, to: cell)
            #expect(frame.width >= 44)
            #expect(frame.height >= 44)
            #expect(cell.bounds.contains(frame))
        }

        for firstIndex in buttons.indices {
            for secondIndex in buttons.indices where firstIndex < secondIndex {
                let firstFrame = buttons[firstIndex].convert(buttons[firstIndex].bounds, to: cell)
                let secondFrame = buttons[secondIndex].convert(buttons[secondIndex].bounds, to: cell)
                #expect(firstFrame.intersection(secondFrame).isNull)
            }
        }
    }

    @Test("Thinking action hit target includes off-glyph segment around compact label")
    func thinkingActionHitTargetIncludesOffGlyphSegmentAroundCompactLabel() throws {
        let cell = makeConfiguredCell()
        let buttons = allSubviews(in: cell).compactMap { $0 as? UIButton }
        let thinkingButton = try #require(buttons.first { $0.accessibilityLabel == "Thinking high" })
        let thinkingFrame = thinkingButton.convert(thinkingButton.bounds, to: cell)
        let thinkingLabel = try #require(thinkingButton.titleLabel)
        let thinkingLabelFrame = thinkingLabel.convert(thinkingLabel.bounds, to: cell)
        let thinkingRegion = try #require(
            FooterActionHitTesting.actionRegions(for: buttons, in: cell)
                .first { $0.view === thinkingButton }?.rect
        )
        let offGlyphX = max(thinkingFrame.minX + 2, thinkingLabelFrame.minX - 2)
        let offGlyphPoint = CGPoint(x: offGlyphX, y: thinkingRegion.midY)

        #expect(thinkingRegion.width >= 44)
        #expect(thinkingFrame.contains(offGlyphPoint))
        #expect(thinkingLabelFrame.contains(offGlyphPoint) == false)
        #expect(thinkingRegion.contains(offGlyphPoint))
        #expect(cell.hitTest(offGlyphPoint, with: nil) === thinkingButton)
    }

    @Test("Every sampled point inside each visible footer button resolves to that button")
    func everySampledPointInsideEachVisibleFooterButtonResolvesToThatButton() throws {
        let cell = makeConfiguredCell()
        let buttons = try footerButtons(in: cell)

        for button in buttons {
            let frame = button.convert(button.bounds, to: cell)
            let samplePoints = [
                CGPoint(x: frame.midX, y: frame.midY),
                CGPoint(x: frame.minX + 1, y: frame.midY),
                CGPoint(x: frame.maxX - 1, y: frame.midY),
                CGPoint(x: frame.midX, y: frame.minY + 1),
                CGPoint(x: frame.midX, y: frame.maxY - 1),
                CGPoint(x: frame.minX + 1, y: frame.minY + 1),
                CGPoint(x: frame.maxX - 1, y: frame.minY + 1),
                CGPoint(x: frame.minX + 1, y: frame.maxY - 1),
                CGPoint(x: frame.maxX - 1, y: frame.maxY - 1)
            ]

            for point in samplePoints {
                #expect(button.point(inside: cell.convert(point, to: button), with: nil))
                #expect(cell.hitTest(point, with: nil) === button)
            }
        }
    }

    @Test("Direct label glyph taps resolve to the enabled footer button")
    func directLabelGlyphTapsResolveToTheEnabledFooterButton() throws {
        let cell = makeConfiguredCell()
        let buttons = try footerButtons(in: cell)

        for button in buttons {
            let titleLabel = try #require(button.titleLabel)
            let labelFrameInButton = titleLabel.convert(titleLabel.bounds, to: button)
            let labelCenterInButton = CGPoint(x: labelFrameInButton.midX, y: labelFrameInButton.midY)
            let labelCenterInCell = button.convert(labelCenterInButton, to: cell)

            #expect(titleLabel.bounds.width > 0)
            #expect(titleLabel.bounds.height > 0)
            #expect(titleLabel.point(inside: titleLabel.convert(labelCenterInCell, from: cell), with: nil))
            #expect(button.hitTest(labelCenterInButton, with: nil) === button)
            #expect(cell.hitTest(labelCenterInCell, with: nil) === button)
        }
    }

    @Test("Footer action regions keep compact borderless styling")
    func footerActionRegionsKeepCompactBorderlessStyling() throws {
        let cell = makeConfiguredCell()
        let buttons = allSubviews(in: cell).compactMap { $0 as? UIButton }
        let thinkingButton = try #require(buttons.first { $0.accessibilityLabel == "Thinking high" })
        let configuration = try #require(thinkingButton.configuration)

        #expect(configuration.contentInsets.top == 2)
        #expect(configuration.contentInsets.bottom == 2)
        #expect(configuration.contentInsets.leading == 4)
        #expect(configuration.contentInsets.trailing == 4)
        #expect(configuration.background.strokeWidth == 0)
        #expect(configuration.background.backgroundColor?.cgColor.alpha == 0)
    }
}

private func makeConfiguredCell() -> SessionMetadataFooterCell {
    let status = SessionStatus(
        sessionKey: "agent:main:clawline:user:s_test",
        display: .init(
            model: "gpt-5.5",
            fallbackModels: ["gpt-5.5", "claude-sonnet-4.6"],
            provider: "openai",
            harness: nil,
            reasoningLevel: nil,
            thinkingLevel: "high",
            fastMode: true,
            mode: nil,
            verbosity: nil
        ),
        run: .init(
            state: .idle,
            runId: nil,
            messageId: nil,
            startedAt: nil,
            queueDepth: nil
        ),
        context: nil,
        approval: nil,
        capabilities: .init(
            cancelCurrentRun: nil,
            setModel: .init(supported: true, reason: nil),
            setThinking: .init(supported: true, reason: nil),
            setReasoning: nil,
            setFastMode: .init(supported: true, reason: nil),
            setMode: nil,
            setVerbosity: nil,
            canCancelCurrentRun: nil,
            canChangeModel: nil,
            canChangeReasoning: nil,
            canChangeFastMode: nil,
            canChangeVerbosity: nil,
            readOnlyStatus: nil
        ),
        modelCatalog: nil
    )
    let cell = SessionMetadataFooterCell(
        frame: CGRect(
            x: 0,
            y: 0,
            width: 320,
            height: SessionMetadataFooterCell.height(for: status)
        )
    )
    cell.configure(status: status, isDark: false, onSelect: { _, _, _, _ in })
    cell.setNeedsLayout()
    cell.layoutIfNeeded()
    return cell
}

private func allSubviews(in view: UIView) -> [UIView] {
    view.subviews + view.subviews.flatMap { allSubviews(in: $0) }
}

@MainActor
private func footerButtons(in cell: SessionMetadataFooterCell) throws -> [UIButton] {
    let buttons = allSubviews(in: cell)
        .compactMap { $0 as? UIButton }
        .filter { $0.isEnabled }
        .sorted {
            $0.convert($0.bounds, to: cell).minX < $1.convert($1.bounds, to: cell).minX
        }
    #expect(buttons.map(\.accessibilityLabel) == ["gpt-5.5", "Thinking high", "Fast on"])
    return try #require(buttons.count == 3 ? buttons : nil)
}
