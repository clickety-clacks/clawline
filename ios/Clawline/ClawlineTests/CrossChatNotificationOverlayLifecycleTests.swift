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

    @Test func ordinaryChatNavigationDoesNotDockUndockedNotifications() {
        #expect(
            !CrossChatNotificationNavigationDockPolicy.shouldDock(
                origin: .ordinaryChatNavigation,
                isSwitchingChats: true,
                hasNotifications: true
            )
        )
    }

    @Test func notificationOriginNavigationDocksWhenSwitchingWithNotifications() {
        #expect(
            CrossChatNotificationNavigationDockPolicy.shouldDock(
                origin: .notificationNavigation,
                isSwitchingChats: true,
                hasNotifications: true
            )
        )
        #expect(
            !CrossChatNotificationNavigationDockPolicy.shouldDock(
                origin: .notificationNavigation,
                isSwitchingChats: false,
                hasNotifications: true
            )
        )
        #expect(
            !CrossChatNotificationNavigationDockPolicy.shouldDock(
                origin: .notificationNavigation,
                isSwitchingChats: true,
                hasNotifications: false
            )
        )
    }
}
