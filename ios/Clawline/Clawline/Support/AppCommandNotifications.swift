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
}

struct CancelCurrentPromptCommand {
    let presentConfirmation: @MainActor () -> Void
}

private struct CancelCurrentPromptCommandKey: FocusedValueKey {
    typealias Value = CancelCurrentPromptCommand
}

extension FocusedValues {
    var cancelCurrentPromptCommand: CancelCurrentPromptCommand? {
        get { self[CancelCurrentPromptCommandKey.self] }
        set { self[CancelCurrentPromptCommandKey.self] = newValue }
    }
}
