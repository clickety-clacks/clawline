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
}
