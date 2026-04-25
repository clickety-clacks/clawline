//
//  AppCommandNotifications.swift
//  Clawline
//

import Foundation

extension Notification.Name {
    static let clawlineFocusPromptInputCommand = Notification.Name("clawline.focusPromptInputCommand")
    static let clawlineOpenStreamPopupCommand = Notification.Name("clawline.openStreamPopupCommand")
    static let clawlineNavigateToPreviousStreamCommand = Notification.Name("clawline.navigateToPreviousStreamCommand")
    static let clawlineNavigateToNextStreamCommand = Notification.Name("clawline.navigateToNextStreamCommand")
    static let clawlineScrollDownCommand = Notification.Name("clawline.scrollDownCommand")
    static let clawlineScrollUpCommand = Notification.Name("clawline.scrollUpCommand")
}
