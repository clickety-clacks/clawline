import Testing
@testable import Clawline

@MainActor
struct DictationMicAffordanceAnimationPlanTests {
    @Test("Debug settle multiplier honors environment override")
    func debugSettleMultiplierHonorsEnvironmentOverride() {
        let resolved = DictationMotion.resolveDebugSettleDurationMultiplier(
            environment: ["CLAWLINE_DICTATION_SETTLE_MULTIPLIER": "2.0"]
        )

        #expect(resolved == 2.0)
    }

    @Test("Debug settle multiplier falls back to default when missing")
    func debugSettleMultiplierFallsBackToDefault() {
        let resolved = DictationMotion.resolveDebugSettleDurationMultiplier(environment: [:])

        #expect(resolved == 1.0)
    }

    @Test("Swipe-left plan includes visible right-edge re-entry before fade")
    func swipePlanUsesSlideThenFade() {
        let plan = DictationMicAffordanceAnimationPlan.make(fromSwipe: true)

        #expect(plan.initialOffset > .zero)
        #expect(plan.slideDurationMs == 350)
        #expect(plan.fadeDelayMs == 350)
        #expect(plan.fadeDurationMs == 850)
    }

    @Test("Tap plan fades directly without swipe re-entry slide")
    func tapPlanUsesDirectFade() {
        let plan = DictationMicAffordanceAnimationPlan.make(fromSwipe: false)

        #expect(plan.initialOffset == .zero)
        #expect(plan.slideDurationMs == nil)
        #expect(plan.fadeDelayMs == 0)
        #expect(plan.fadeDurationMs == 1_200)
    }
}
