//
//  AppCommandNotifications.swift
//  Clawline
//

import Foundation
import SwiftUI

extension Notification.Name {
    static let clawlineFocusPromptInputCommand = Notification.Name("clawline.focusPromptInputCommand")
    static let clawlineOpenStreamPopupCommand = Notification.Name("clawline.openStreamPopupCommand")
    static let clawlineNavigateToPreviousStreamCommand = Notification.Name("clawline.navigateToPreviousStreamCommand")
    static let clawlineNavigateToNextStreamCommand = Notification.Name("clawline.navigateToNextStreamCommand")
    static let clawlineScrollDownCommand = Notification.Name("clawline.scrollDownCommand")
    static let clawlineScrollUpCommand = Notification.Name("clawline.scrollUpCommand")
    static let clawlineScrollChatDownCommand = Notification.Name("clawline.scrollChatDownCommand")
    static let clawlineScrollChatUpCommand = Notification.Name("clawline.scrollChatUpCommand")
    static let clawlineScrollNotificationDownCommand = Notification.Name("clawline.scrollNotificationDownCommand")
    static let clawlineScrollNotificationUpCommand = Notification.Name("clawline.scrollNotificationUpCommand")
    static let clawlineToggleNotificationDockCommand = Notification.Name("clawline.toggleNotificationDockCommand")
    static let clawlineOpenNotificationActionMenuCommand = Notification.Name("clawline.openNotificationActionMenuCommand")
    static let clawlineReplyNotificationCommand = Notification.Name("clawline.replyNotificationCommand")
    static let clawlineDismissNotificationCommand = Notification.Name("clawline.dismissNotificationCommand")
}

struct CancelCurrentPromptCommand {
    let presentConfirmation: @MainActor () -> Void
}

struct CrossChatNotificationCommand {
    let hasVisibleNotifications: Bool
    let visibleCount: Int
    let openActionMenu: @MainActor (Int) -> Void
    let dismiss: @MainActor (Int) -> Void
    let reply: @MainActor (Int) -> Void
    let dismissAll: @MainActor () -> Void
}

private struct CancelCurrentPromptCommandKey: FocusedValueKey {
    typealias Value = CancelCurrentPromptCommand
}

private struct CrossChatNotificationCommandKey: FocusedValueKey {
    typealias Value = CrossChatNotificationCommand
}

extension FocusedValues {
    var cancelCurrentPromptCommand: CancelCurrentPromptCommand? {
        get { self[CancelCurrentPromptCommandKey.self] }
        set { self[CancelCurrentPromptCommandKey.self] = newValue }
    }

    var crossChatNotificationCommand: CrossChatNotificationCommand? {
        get { self[CrossChatNotificationCommandKey.self] }
        set { self[CrossChatNotificationCommandKey.self] = newValue }
    }
}
