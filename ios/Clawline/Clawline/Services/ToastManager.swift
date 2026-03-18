//
//  ToastManager.swift
//  Clawline
//
//  Created by Codex on 1/15/26.
//

import Foundation
import Observation

@Observable
@MainActor
final class ToastManager {
    struct Toast: Identifiable, Equatable {
        let id = UUID()
        let message: String
        let actionTitle: String?
        let action: (@MainActor () -> Void)?

        static func == (lhs: Toast, rhs: Toast) -> Bool {
            lhs.id == rhs.id
                && lhs.message == rhs.message
                && lhs.actionTitle == rhs.actionTitle
        }
    }

    private(set) var toast: Toast?
    private var dismissTask: Task<Void, Never>?
#if DEBUG
    private(set) var debugMessages: [String] = []
#endif

    func show(_ message: String,
              duration: Duration = .seconds(3),
              actionTitle: String? = nil,
              action: (@MainActor () -> Void)? = nil) {
        guard !message.isEmpty else { return }
        toast = Toast(message: message, actionTitle: actionTitle, action: action)
#if DEBUG
        debugMessages.append(message)
#endif
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            do {
                try await Task.sleep(forDuration: duration)
            } catch is CancellationError {
                return
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.dismiss()
            }
        }
    }

    func show(error: AttachmentError) {
        guard let description = error.errorDescription else { return }
        show(description)
    }

    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        toast = nil
    }

    func performAction() {
        guard let action = toast?.action else { return }
        dismiss()
        action()
    }

#if DEBUG
    func debugLastMessage() -> String? {
        debugMessages.last
    }
#endif
}
