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
    }

    private(set) var toast: Toast?
    private var dismissTask: Task<Void, Never>?
#if DEBUG
    private(set) var debugMessages: [String] = []
#endif

    func show(_ message: String, duration: Duration = .seconds(3)) {
        guard !message.isEmpty else { return }
        toast = Toast(message: message)
#if DEBUG
        debugMessages.append(message)
#endif
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
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

#if DEBUG
    func debugLastMessage() -> String? {
        debugMessages.last
    }
#endif
}
