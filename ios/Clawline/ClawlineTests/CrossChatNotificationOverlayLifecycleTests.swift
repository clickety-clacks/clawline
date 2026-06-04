//
//  CrossChatNotificationOverlayLifecycleTests.swift
//  ClawlineTests
//

import Testing
@testable import Clawline

struct CrossChatNotificationOverlayLifecycleTests {
    @Test func browserSurfaceDisappearPreservesCollapsedStateWhileNotificationsRemainVisible() {
        #expect(
            !CrossChatNotificationOverlayLifecycle.shouldResetCollapsedStateOnDisappear()
        )
    }

    @Test func browserSurfaceDisappearPreservesCollapsedStateDuringTransientEmptyOverlay() {
        #expect(
            !CrossChatNotificationOverlayLifecycle.shouldResetCollapsedStateOnDisappear()
        )
    }

    @Test func clearingVisibleNotificationsResetsCollapsedState() {
        #expect(
            CrossChatNotificationOverlayLifecycle.shouldResetCollapsedStateOnBubbleCountChange(
                visibleBubbleCount: 0
            )
        )
        #expect(
            !CrossChatNotificationOverlayLifecycle.shouldResetCollapsedStateOnBubbleCountChange(
                visibleBubbleCount: 1
            )
        )
    }
}
