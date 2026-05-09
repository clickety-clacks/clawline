import Testing
import UIKit
@testable import Clawline

@MainActor
struct SessionMetadataFooterHitTestingTests {
    @Test("Footer action regions are stable non-overlapping tap targets")
    func footerActionRegionsAreStableNonOverlappingTapTargets() throws {
        let cell = makeConfiguredCell()
        let buttons = try footerButtons(in: cell)
        let frames = buttons.map { $0.convert($0.bounds, to: cell) }

        for frame in frames {
            #expect(frame.width >= 44)
            #expect(frame.height <= 24)
            #expect(cell.bounds.contains(frame))
        }

        for firstIndex in frames.indices {
            for secondIndex in frames.indices where firstIndex < secondIndex {
                let firstFrame = frames[firstIndex]
                let secondFrame = frames[secondIndex]
                #expect(firstFrame.intersection(secondFrame).isNull)
            }
        }

        for index in frames.indices.dropFirst() {
            let gap = frames[index].minX - frames[index - 1].maxX
            #expect(gap <= 2.5)
            #expect(gap >= 0)
        }

        let occupiedWidth = frames.last!.maxX - frames.first!.minX
        #expect(occupiedWidth < cell.bounds.width * 0.7)
    }

    @Test("Footer actions sit in compact reveal row")
    func footerActionsSitInCompactRevealRow() throws {
        let cell = makeConfiguredCell()
        let buttons = try footerButtons(in: cell)
        let frames = buttons.map { $0.convert($0.bounds, to: cell) }

        #expect(SessionMetadataFooterCell.topPadding == 12)
        #expect(SessionMetadataFooterCell.height(for: makeStatus()) == 60)
        #expect(SessionMetadataFooterCell.fadeRevealRange == 56)
        #expect(frames.allSatisfy {
            let centeredY = SessionMetadataFooterCell.topPadding
                + (SessionMetadataFooterCell.actionRegionHeight - $0.height) / 2
            return abs($0.minY - centeredY) <= 0.5
        })
        #expect(frames.allSatisfy { $0.height <= 24 })
    }

    @Test("Thinking action hit target does not include off-glyph segment above compact label")
    func thinkingActionHitTargetDoesNotIncludeOffGlyphSegmentAboveCompactLabel() throws {
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
        let offGlyphPoint = CGPoint(x: thinkingLabelFrame.midX, y: thinkingFrame.minY - 1)

        #expect(thinkingRegion.width >= 44)
        #expect(thinkingFrame.contains(offGlyphPoint) == false)
        #expect(thinkingLabelFrame.contains(offGlyphPoint) == false)
        #expect(thinkingRegion.contains(offGlyphPoint) == false)
        #expect(cell.hitTest(offGlyphPoint, with: nil) !== thinkingButton)
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

    @Test("Footer text keeps readable opacity without changing reveal mechanics")
    func footerTextKeepsReadableOpacity() throws {
        let cell = makeConfiguredCell()
        let buttons = allSubviews(in: cell).compactMap { $0 as? UIButton }
        let modelButton = try #require(buttons.first { $0.accessibilityLabel == "gpt-5.5" })
        let configuration = try #require(modelButton.configuration)
        let foreground = try #require(configuration.baseForegroundColor)

        #expect(foreground.cgColor.alpha == SessionMetadataFooterCell.textAlpha(isDark: false))
        #expect(SessionMetadataFooterCell.fadeRevealRange == 56)
    }

    @Test("Popup selectors mark current item with checkmark image instead of text")
    func popupSelectorsMarkCurrentItemWithCheckmarkImageInsteadOfText() throws {
        let cell = makeConfiguredCell()
        let buttons = try footerButtons(in: cell)
        let expectedCurrentTitlesByButton = [
            "gpt-5.5": "gpt-5.5",
            "Thinking high": "high",
            "Fast on": "On"
        ]

        for button in buttons {
            let actions = try #require(button.menu?.children.compactMap { $0 as? UIAction })
            #expect(actions.allSatisfy { !$0.title.localizedCaseInsensitiveContains("(current)") })

            let currentTitle = try #require(expectedCurrentTitlesByButton[button.accessibilityLabel ?? ""])
            let currentAction = try #require(actions.first { $0.title == currentTitle })
            #expect(currentAction.image != nil)
            #expect(currentAction.discoverabilityTitle == "\(currentTitle), Current")

            for action in actions where action.title != currentTitle {
                #expect(action.image == nil)
                #expect(action.discoverabilityTitle == action.title)
            }
        }
    }
}

private func makeConfiguredCell() -> SessionMetadataFooterCell {
    let status = makeStatus()
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

private func makeStatus() -> SessionStatus {
    SessionStatus(
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
