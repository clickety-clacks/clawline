import CoreFoundation
import Testing
@testable import Clawline

struct BottomInsetHeightCapInvalidationTests {
    @Test("Active input skips height-cap invalidation for input-bar growth")
    func activeInputGrowthIsIgnored() {
        let shouldSchedule = MessageFlowCollectionViewController.shouldScheduleBottomInsetHeightCapInvalidation(
            previousBottomInset: 284,
            newBottomInset: 316,
            isInputActive: true
        )

        #expect(shouldSchedule == false)
    }

    @Test("Active input skips height-cap invalidation even for large inset collapse")
    func activeInputLargeCollapseIsIgnored() {
        let shouldSchedule = MessageFlowCollectionViewController.shouldScheduleBottomInsetHeightCapInvalidation(
            previousBottomInset: 420,
            newBottomInset: 280,
            isInputActive: true
        )

        #expect(shouldSchedule == false)
    }

    @Test("Inactive inset changes still queue invalidation")
    func inactiveInsetChangeStillQueues() {
        let shouldSchedule = MessageFlowCollectionViewController.shouldScheduleBottomInsetHeightCapInvalidation(
            previousBottomInset: 180,
            newBottomInset: 212,
            isInputActive: false
        )

        #expect(shouldSchedule == true)
    }
}
