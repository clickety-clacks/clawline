import Testing
@testable import Clawline

@MainActor
@Suite(.serialized)
struct StreamToastManagerTests {
    @Test("T179: stream toast dismisses after configured idle delay")
    func dismissesAfterConfiguredIdleDelay() {
        let time = ManualStreamToastTiming()
        let manager = StreamToastManager(
            dismissDelay: .milliseconds(120),
            timing: time.timing
        )

        manager.show(displayName: "Main", sessionKey: "agent:main:clawline:flynn:main")
        #expect(manager.isVisible)

        time.advance(by: .milliseconds(60))
        #expect(manager.isVisible)

        time.advance(by: .milliseconds(60))
        #expect(!manager.isVisible)
    }

    @Test("T179: busy time counts against the total stream toast window")
    func busyTimeCountsAgainstTotalWindow() {
        let time = ManualStreamToastTiming()
        let manager = StreamToastManager(
            dismissDelay: .milliseconds(180),
            timing: time.timing
        )

        manager.show(
            displayName: "Main",
            sessionKey: "agent:main:clawline:flynn:main",
            isBusy: true
        )
        #expect(manager.isVisible)

        time.advance(by: .milliseconds(120))

        manager.setBusy(false)
        #expect(manager.isVisible)

        time.advance(by: .milliseconds(40))
        #expect(manager.isVisible)

        time.advance(by: .milliseconds(20))
        #expect(!manager.isVisible)
    }

    @Test("T257: scrub preview toast remains pinned until release updates it")
    func scrubPreviewToastRemainsPinnedUntilReleaseUpdate() {
        let time = ManualStreamToastTiming()
        let manager = StreamToastManager(
            dismissDelay: .milliseconds(80),
            timing: time.timing
        )

        manager.show(
            displayName: "Preview",
            sessionKey: "agent:main:clawline:flynn:preview",
            autoDismiss: false
        )

        #expect(manager.isVisible)
        #expect(manager.displayName == "Preview")
        #expect(manager.isAutoDismissEnabled == false)

        time.advance(by: .milliseconds(800))
        #expect(manager.isVisible)

        manager.show(
            displayName: "Released",
            sessionKey: "agent:main:clawline:flynn:released"
        )

        #expect(manager.isVisible)
        #expect(manager.displayName == "Released")
        #expect(manager.isAutoDismissEnabled)

        time.advance(by: .milliseconds(80))
        #expect(!manager.isVisible)
    }
}

@MainActor
private final class ManualStreamToastTiming {
    private struct ScheduledAction {
        let deadline: Duration
        let action: StreamToastManager.Timing.Action
    }

    private var elapsed: Duration = .zero
    private var nextID = 0
    private var scheduledActions: [Int: ScheduledAction] = [:]

    lazy var timing = StreamToastManager.Timing(
        now: { [unowned self] in elapsed },
        schedule: { [unowned self] delay, action in
            let id = nextID
            nextID += 1
            scheduledActions[id] = ScheduledAction(deadline: elapsed + delay, action: action)
            return { [weak self] in
                self?.scheduledActions.removeValue(forKey: id)
            }
        }
    )

    func advance(by duration: Duration) {
        elapsed += duration
        while let due = scheduledActions
            .filter({ $0.value.deadline <= elapsed })
            .min(by: { $0.key < $1.key }) {
            scheduledActions.removeValue(forKey: due.key)
            due.value.action()
        }
    }
}
