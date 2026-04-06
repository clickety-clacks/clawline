import Testing
@testable import Clawline

@MainActor
struct StreamToastManagerTests {
    @Test("T179: stream toast dismisses after configured idle delay")
    func dismissesAfterConfiguredIdleDelay() async {
        let manager = StreamToastManager(dismissDelay: .milliseconds(120))

        manager.show(displayName: "Main", sessionKey: "agent:main:clawline:flynn:main")
        #expect(manager.isVisible)

        do {
            try await Task.sleep(for: .milliseconds(60))
        } catch {
            Issue.record("Sleep unexpectedly failed: \(error)")
            return
        }
        #expect(manager.isVisible)

        do {
            try await Task.sleep(for: .milliseconds(90))
        } catch {
            Issue.record("Sleep unexpectedly failed: \(error)")
            return
        }
        #expect(!manager.isVisible)
    }

    @Test("T179: busy time counts against the total stream toast window")
    func busyTimeCountsAgainstTotalWindow() async {
        let manager = StreamToastManager(dismissDelay: .milliseconds(180))

        manager.show(
            displayName: "Main",
            sessionKey: "agent:main:clawline:flynn:main",
            isBusy: true
        )
        #expect(manager.isVisible)

        do {
            try await Task.sleep(for: .milliseconds(120))
        } catch {
            Issue.record("Sleep unexpectedly failed: \(error)")
            return
        }

        manager.setBusy(false)
        #expect(manager.isVisible)

        do {
            try await Task.sleep(for: .milliseconds(40))
        } catch {
            Issue.record("Sleep unexpectedly failed: \(error)")
            return
        }
        #expect(manager.isVisible)

        do {
            try await Task.sleep(for: .milliseconds(50))
        } catch {
            Issue.record("Sleep unexpectedly failed: \(error)")
            return
        }
        #expect(!manager.isVisible)
    }
}
