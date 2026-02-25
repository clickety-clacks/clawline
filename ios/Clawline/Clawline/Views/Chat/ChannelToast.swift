//
//  StreamToast.swift
//  Clawline
//
//  Created by Claude on 1/24/26.
//

import SwiftUI

/// A Liquid Glass toast that displays the current channel name.
/// Designed for debounced display during swipe-to-switch gestures.
struct StreamToast: View {
    let displayName: String
    let sessionKey: String
    let isBusy: Bool

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.settingsManager) private var settings

    private var isDarkMode: Bool {
#if os(visionOS)
        return settings.appearanceMode == .dark
#else
        return colorScheme == .dark
#endif
    }

    private var toastTextColor: Color {
#if os(visionOS)
        return isDarkMode ? .black : .white
#else
        return isDarkMode ? .white : .primary
#endif
    }

#if os(visionOS)
    private var toastBackgroundColor: Color {
        isDarkMode ? Color.white.opacity(0.85) : Color.black.opacity(0.7)
    }
#endif

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .tint(toastTextColor)
                }
                Text(displayName)
                    .font(.clawline(.sectionHeader))
                    .foregroundStyle(toastTextColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.center)
            }

            Text(sessionKey)
                .font(.clawline(.secondaryLabel))
                .foregroundStyle(toastTextColor.opacity(0.7))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 20)
#if os(visionOS)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(toastBackgroundColor)
        )
#else
        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
#endif
        .shadow(color: .black.opacity(0.15), radius: 20, x: 0, y: 10)
    }
}

/// Manages the channel toast display with debounce behavior.
/// Toast stays visible while switching and only dismisses after 1 second of no activity.
@Observable
@MainActor
final class StreamToastManager {
    private(set) var isVisible = false
    private(set) var displayName: String = ""
    private(set) var sessionKey: String = ""
    private(set) var isBusy = false

    private var dismissTask: Task<Void, Never>?
    private let dismissDelay: Duration = .seconds(2)

    /// Shows or updates the toast with stream display metadata.
    /// If already visible, just updates the name without dismissing.
    func show(displayName: String, sessionKey: String, isBusy: Bool = false) {
        // Cancel any pending dismiss
        dismissTask?.cancel()
        dismissTask = nil

        // Update displayed metadata and show
        self.displayName = displayName
        self.sessionKey = sessionKey
        self.isBusy = isBusy
        isVisible = true

        scheduleDismissIfIdle()
    }

    func setBusy(_ busy: Bool) {
        guard isVisible else { return }
        dismissTask?.cancel()
        dismissTask = nil
        isBusy = busy
        scheduleDismissIfIdle()
    }

    private func scheduleDismissIfIdle() {
        guard isVisible, !isBusy else { return }
        dismissTask = Task {
            try? await Task.sleep(for: dismissDelay)
            guard !Task.isCancelled else { return }
            isVisible = false
        }
    }

    /// Immediately hides the toast.
    func hide() {
        dismissTask?.cancel()
        dismissTask = nil
        isBusy = false
        isVisible = false
    }
}

#Preview {
    ZStack {
        Color.gray.opacity(0.3)
            .ignoresSafeArea()

        StreamToast(displayName: "Main", sessionKey: "agent:main:clawline:preview:main", isBusy: true)
    }
}
