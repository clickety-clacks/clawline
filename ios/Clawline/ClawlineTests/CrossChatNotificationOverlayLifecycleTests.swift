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
        #expect(
            !CrossChatNotificationOverlayLifecycle.shouldClearCollapsedPreviewsOnDisappear(
                visibleBubbleCount: 1
            )
        )
    }

    @Test func browserSurfaceDisappearPreservesCollapsedStateDuringTransientEmptyOverlay() {
        #expect(
            !CrossChatNotificationOverlayLifecycle.shouldResetCollapsedStateOnDisappear()
        )
    }

    @Test func emptyOverlayDisappearClearsCollapsedPreviews() {
        #expect(
            CrossChatNotificationOverlayLifecycle.shouldClearCollapsedPreviewsOnDisappear(
                visibleBubbleCount: 0
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

    @Test func ordinaryChatSwitchSourceDismissalDoesNotPreviewUnrelatedNotifications() {
        #expect(
            CrossChatNotificationOverlayLifecycle.sourceChatIdsNeedingCollapsedPreview(
                previousVisibleSourceChatIds: ["source", "unrelated"],
                currentVisibleSourceChatIds: ["unrelated"]
            )
            .isEmpty
        )
    }

    @Test func newlyVisibleNotificationsMayStartCollapsedPreview() {
        #expect(
            CrossChatNotificationOverlayLifecycle.sourceChatIdsNeedingCollapsedPreview(
                previousVisibleSourceChatIds: ["source"],
                currentVisibleSourceChatIds: ["new", "source"]
            ) == ["new"]
        )
    }
}
