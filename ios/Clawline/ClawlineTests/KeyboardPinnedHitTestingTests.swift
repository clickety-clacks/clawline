import Testing
import UIKit
@testable import Clawline

@MainActor
struct KeyboardPinnedHitTestingTests {
    @Test("Pinned-container hit testing honors custom hit regions instead of raw frames")
    func expandedHitRegionCountsAsInteractive() {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        let candidate = ExpandedHitRegionView(frame: CGRect(x: 100, y: 100, width: 24, height: 24))
        container.addSubview(candidate)

        let pointOutsideFrameButInsideExpandedRegion = CGPoint(x: 92, y: 92)

        #expect(candidate.frame.contains(pointOutsideFrameButInsideExpandedRegion) == false)
        #expect(
            KeyboardPinnedHitTesting.contains(
                pointOutsideFrameButInsideExpandedRegion,
                in: candidate,
                from: container,
                event: nil
            )
        )
    }

    @Test("Pinned-container hit testing ignores non-interactive candidates")
    func nonInteractiveCandidatesDoNotCaptureTouches() {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        let candidate = ExpandedHitRegionView(frame: CGRect(x: 100, y: 100, width: 24, height: 24))
        candidate.isUserInteractionEnabled = false
        container.addSubview(candidate)

        #expect(
            KeyboardPinnedHitTesting.contains(
                CGPoint(x: 100, y: 100),
                in: candidate,
                from: container,
                event: nil
            ) == false
        )
    }

    @Test("Pinned scroll-bottom event routing follows visibility, not host existence")
    func pinnedScrollBottomEventRoutingFollowsVisibilityNotHostExistence() {
        #expect(KeyboardPinnedChromeEventRouting.scrollButtonHostReceivesEvents(hasView: false, isVisible: false) == false)
        #expect(KeyboardPinnedChromeEventRouting.scrollButtonHostReceivesEvents(hasView: true, isVisible: false) == false)
        #expect(KeyboardPinnedChromeEventRouting.scrollButtonHostReceivesEvents(hasView: true, isVisible: true))
    }

    @Test("Hidden scroll-bottom host does not intercept footer action taps")
    func hiddenScrollBottomHostDoesNotInterceptFooterActionTaps() throws {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
        let footerCell = makeConfiguredFooterCell()
        footerCell.frame.origin.y = 60
        container.addSubview(footerCell)

        let thinkingButton = try #require(footerButtons(in: footerCell).first { $0.accessibilityLabel == "Thinking high" })
        let label = try #require(thinkingButton.titleLabel)
        let labelCenter = label.convert(CGPoint(x: label.bounds.midX, y: label.bounds.midY), to: container)
        let hiddenScrollButtonHost = UIView(frame: CGRect(x: labelCenter.x - 22, y: labelCenter.y - 22, width: 44, height: 44))
        hiddenScrollButtonHost.backgroundColor = .clear
        hiddenScrollButtonHost.isUserInteractionEnabled = false
        container.addSubview(hiddenScrollButtonHost)

        #expect(
            KeyboardPinnedHitTesting.contains(
                labelCenter,
                in: hiddenScrollButtonHost,
                from: container,
                event: nil
            ) == false
        )
        #expect(container.hitTest(labelCenter, with: nil) === thinkingButton)
    }

    @Test("Visible scroll-bottom host still receives taps in its region")
    func visibleScrollBottomHostStillReceivesTapsInItsRegion() throws {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
        let footerCell = makeConfiguredFooterCell()
        footerCell.frame.origin.y = 60
        container.addSubview(footerCell)

        let thinkingButton = try #require(footerButtons(in: footerCell).first { $0.accessibilityLabel == "Thinking high" })
        let label = try #require(thinkingButton.titleLabel)
        let labelCenter = label.convert(CGPoint(x: label.bounds.midX, y: label.bounds.midY), to: container)
        let visibleScrollButtonHost = ExpandedHitRegionView(
            frame: CGRect(x: labelCenter.x - 22, y: labelCenter.y - 22, width: 44, height: 44)
        )
        visibleScrollButtonHost.backgroundColor = .clear
        visibleScrollButtonHost.isUserInteractionEnabled = true
        container.addSubview(visibleScrollButtonHost)

        #expect(
            KeyboardPinnedHitTesting.contains(
                labelCenter,
                in: visibleScrollButtonHost,
                from: container,
                event: nil
            )
        )
        #expect(container.hitTest(labelCenter, with: nil) === visibleScrollButtonHost)
    }
}

private final class ExpandedHitRegionView: UIView {
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: -12, dy: -12).contains(point)
    }
}

private func makeConfiguredFooterCell() -> SessionMetadataFooterCell {
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

private func footerButtons(in cell: SessionMetadataFooterCell) -> [UIButton] {
    allSubviews(in: cell)
        .compactMap { $0 as? UIButton }
        .filter { $0.isEnabled }
        .sorted {
            $0.convert($0.bounds, to: cell).minX < $1.convert($1.bounds, to: cell).minX
        }
}

private func allSubviews(in view: UIView) -> [UIView] {
    view.subviews + view.subviews.flatMap { allSubviews(in: $0) }
}
