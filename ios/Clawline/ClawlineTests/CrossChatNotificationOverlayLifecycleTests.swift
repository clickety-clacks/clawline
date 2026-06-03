//
//  CrossChatNotificationOverlayLifecycleTests.swift
//  ClawlineTests
//

import Testing
@testable import Clawline

struct CrossChatNotificationOverlayLifecycleTests {
    @Test func browserSurfaceDisappearPreservesCollapsedStateWhileNotificationsRemainVisible() {
        #expect(
            !CrossChatNotificationOverlayLifecycle.shouldResetCollapsedStateOnDisappear(
                hasVisibleBubbles: true
            )
        )
    }

    @Test func emptyNotificationOverlayDisappearResetsCollapsedState() {
        #expect(
            CrossChatNotificationOverlayLifecycle.shouldResetCollapsedStateOnDisappear(
                hasVisibleBubbles: false
            )
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
