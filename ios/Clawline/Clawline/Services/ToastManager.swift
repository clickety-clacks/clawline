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

    func show(_ message: String, duration: Duration = .seconds(3)) {
        guard !message.isEmpty else { return }
        toast = Toast(message: message)
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            await self?.dismiss()
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
}
