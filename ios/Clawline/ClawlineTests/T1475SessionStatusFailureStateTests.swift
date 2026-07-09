//
//  T1475SessionStatusFailureStateTests.swift
//  ClawlineTests
//
//  Footer invariant: session-status fetch failures must surface a truthful
//  unavailable state instead of leaving the footer on "loading" forever.
//

import Foundation
import Testing
@testable import Clawline

@MainActor
struct T1475SessionStatusFailureStateTests {
    private func makeViewModel() -> ChatViewModel {
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        return ChatViewModel(
            auth: auth,
            chatService: TestChatService(),
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: UploadService(auth: auth),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
    }

    @Test("Repeated status fetch failures back off then mark the session unavailable")
    func repeatedFailuresBackOffThenMarkUnavailable() {
        let viewModel = makeViewModel()
        defer { viewModel.onDisappear() }
        let key = "agent:main:clawline:user:s_t1475"

        #expect(viewModel.recordSessionStatusFetchFailure(for: key) == .seconds(2))
        #expect(!viewModel.isSessionStatusUnavailable(for: key))

        #expect(viewModel.recordSessionStatusFetchFailure(for: key) == .seconds(8))
        #expect(!viewModel.isSessionStatusUnavailable(for: key))

        #expect(viewModel.recordSessionStatusFetchFailure(for: key) == .seconds(30))
        #expect(viewModel.isSessionStatusUnavailable(for: key))

        // Steady self-heal cadence persists while unavailable.
        #expect(viewModel.recordSessionStatusFetchFailure(for: key) == .seconds(30))
        #expect(viewModel.isSessionStatusUnavailable(for: key))
    }

    @Test("A successful status fetch clears the failure and unavailable state")
    func successClearsFailureState() {
        let viewModel = makeViewModel()
        defer { viewModel.onDisappear() }
        let key = "agent:main:clawline:user:s_t1475"

        for _ in 0..<3 {
            _ = viewModel.recordSessionStatusFetchFailure(for: key)
        }
        #expect(viewModel.isSessionStatusUnavailable(for: key))

        viewModel.recordSessionStatusFetchSuccess(for: key)
        #expect(!viewModel.isSessionStatusUnavailable(for: key))

        // Failure counting restarts from the fast backoff after recovery.
        #expect(viewModel.recordSessionStatusFetchFailure(for: key) == .seconds(2))
    }

    @Test("Footer renders unavailable, not loading, when status is marked unavailable")
    func footerRendersUnavailableState() {
        let loading = SessionMetadataFooterCell.footerText(for: nil, isUnavailable: false)
        #expect(loading?.contains("Model loading") == true)
        #expect(loading?.contains("Thinking loading") == true)
        #expect(loading?.contains("Fast loading") == true)

        let unavailable = SessionMetadataFooterCell.footerText(for: nil, isUnavailable: true)
        #expect(unavailable?.contains("Model unavailable") == true)
        #expect(unavailable?.contains("Thinking unavailable") == true)
        #expect(unavailable?.contains("Fast unavailable") == true)
    }
}
