import Foundation
import Testing
import UIKit
@testable import Clawline

@MainActor
@Suite(.serialized)
struct MessageFlowEngineActivationCompletionTests {
    @Test("T1738: unchanged active-session reactivation completes exactly once")
    func unchangedActiveSessionReactivationCompletesExactlyOnce() async throws {
        let sourceSessionKey = "agent:main:clawline:user:s_t1738_source"
        let targetSessionKey = "agent:main:clawline:user:s_t1738_target"
        let streams = [
            StreamSession(
                sessionKey: sourceSessionKey,
                displayName: "Source",
                kind: "custom",
                orderIndex: 0,
                isBuiltIn: false,
                createdAt: .now,
                updatedAt: .now,
                trackingMode: .serverManaged
            ),
            StreamSession(
                sessionKey: targetSessionKey,
                displayName: "Target",
                kind: "custom",
                orderIndex: 1,
                isBuiltIn: false,
                createdAt: .now,
                updatedAt: .now,
                trackingMode: .serverManaged
            ),
        ]
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let chatService = TestChatService()
        chatService.streams = streams
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: UploadService(auth: auth),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.prepareForReplacement() }

        await viewModel.activate(origin: "test.t1738.unchangedActiveSessionReactivation")
        chatService.emitServiceEvent(.streamSnapshot(streams))
        for _ in 0..<50 where !Set(viewModel.orderedSessionKeys).isSuperset(of: [sourceSessionKey, targetSessionKey]) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(Set(viewModel.orderedSessionKeys).isSuperset(of: [sourceSessionKey, targetSessionKey]))

        viewModel.setActiveSessionKeyForTesting(targetSessionKey)
        let controller = MessageFlowCollectionViewController(nibName: nil, bundle: nil)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        update(controller, with: viewModel, sessionKey: targetSessionKey, isActiveSession: true)
        try await Task.sleep(for: .milliseconds(50))

        viewModel.setActiveSessionKeyForTesting(sourceSessionKey)
        let sequenceBeforeReactivation = viewModel.engineActivationCompletedSequence
        viewModel.requestStreamSwitch(to: targetSessionKey, source: .programmatic)

        update(controller, with: viewModel, sessionKey: targetSessionKey, isActiveSession: false)
        #expect(viewModel.engineActivationCompletedSequence == sequenceBeforeReactivation)

        update(controller, with: viewModel, sessionKey: targetSessionKey, isActiveSession: true)
        #expect(viewModel.engineActivationCompletedSequence == sequenceBeforeReactivation + 1)

        update(controller, with: viewModel, sessionKey: targetSessionKey, isActiveSession: true)
        #expect(viewModel.engineActivationCompletedSequence == sequenceBeforeReactivation + 1)
    }

    private func update(
        _ controller: MessageFlowCollectionViewController,
        with viewModel: ChatViewModel,
        sessionKey: String,
        isActiveSession: Bool
    ) {
        controller.update(
            viewModel: viewModel,
            isCompact: true,
            isActiveSession: isActiveSession,
            isRenderPolicyFrozen: false,
            isInputActive: false,
            keepsKeyboardPinned: false,
            isTypingActive: false,
            topInset: 0,
            truncationBottomInset: 0,
            firstUnreadMessageId: nil,
            unreadCount: 0,
            sessionKey: sessionKey
        )
    }
}
