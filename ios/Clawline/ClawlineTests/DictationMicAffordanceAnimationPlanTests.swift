import Testing
@testable import Clawline

struct DictationMicAffordanceAnimationPlanTests {
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
