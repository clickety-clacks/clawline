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
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: TestChatService(),
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: UploadService(auth: auth),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.prepareForReplacement() }
        viewModel.requestCrossChatNotificationNavigation(to: targetSessionKey)
        let controller = MessageFlowCollectionViewController(nibName: nil, bundle: nil)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        update(controller, with: viewModel, sessionKey: targetSessionKey, isActiveSession: true)
        try await Task.sleep(for: .milliseconds(50))

        viewModel.requestCrossChatNotificationNavigation(to: sourceSessionKey)
        let sequenceBeforeReactivation = viewModel.engineActivationCompletedSequence
        viewModel.requestStreamSwitch(to: targetSessionKey, source: .programmatic)

        update(controller, with: viewModel, sessionKey: targetSessionKey, isActiveSession: false)
        #expect(viewModel.engineActivationCompletedSequence == sequenceBeforeReactivation)

        update(controller, with: viewModel, sessionKey: targetSessionKey, isActiveSession: true)
        #expect(viewModel.engineActivationCompletedSequence == sequenceBeforeReactivation + 1)

        update(controller, with: viewModel, sessionKey: targetSessionKey, isActiveSession: true)
        #expect(viewModel.engineActivationCompletedSequence == sequenceBeforeReactivation + 1)
    }

    @Test("T1738: changed snapshot with a materialization effect completes activation exactly once")
    func changedSnapshotWithMaterializationEffectCompletesActivationExactlyOnce() async throws {
        let sourceSessionKey = "agent:main:clawline:user:s_t1738_effect_source"
        let targetSessionKey = "agent:main:clawline:user:s_t1738_effect_target"
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: TestChatService(),
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: UploadService(auth: auth),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.prepareForReplacement() }
        for index in 0 ..< 75 {
            viewModel.debugUpsertMessage(
                Message(
                    id: "effect-\(index)",
                    role: index.isMultiple(of: 2) ? .user : .assistant,
                    content: "effect message \(index)",
                    timestamp: Date(timeIntervalSince1970: TimeInterval(index)),
                    streaming: false,
                    attachments: [],
                    deviceId: nil,
                    sessionKey: targetSessionKey
                ),
                isServer: true
            )
        }

        viewModel.requestCrossChatNotificationNavigation(to: targetSessionKey)
        let controller = MessageFlowCollectionViewController(nibName: nil, bundle: nil)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        update(controller, with: viewModel, sessionKey: targetSessionKey, isActiveSession: true)
        await Task.yield()
        controller.scrollToTop(animated: false)
        await Task.yield()

        viewModel.requestCrossChatNotificationNavigation(to: sourceSessionKey)
        viewModel.debugUpsertMessage(
            Message(
                id: "effect-75",
                role: .assistant,
                content: "changed snapshot",
                timestamp: Date(timeIntervalSince1970: 75),
                streaming: false,
                attachments: [],
                deviceId: nil,
                sessionKey: targetSessionKey
            ),
            isServer: true
        )
        let sequenceBeforeReactivation = viewModel.engineActivationCompletedSequence
        viewModel.requestStreamSwitch(to: targetSessionKey, source: .programmatic)
        controller.scrollToBottom(animated: false)
        update(controller, with: viewModel, sessionKey: targetSessionKey, isActiveSession: true)
        await Task.yield()

        #expect(viewModel.engineActivationCompletedSequence == sequenceBeforeReactivation + 1)
        update(controller, with: viewModel, sessionKey: targetSessionKey, isActiveSession: true)
        #expect(viewModel.engineActivationCompletedSequence == sequenceBeforeReactivation + 1)
        controller.scrollToTop(animated: false)
        controller.scrollToBottom(animated: false)
        update(controller, with: viewModel, sessionKey: targetSessionKey, isActiveSession: true)
        #expect(viewModel.engineActivationCompletedSequence == sequenceBeforeReactivation + 1)
    }

    @Test("T1738: rapid A-B-A and inactive pages complete only the final active target")
    func rapidSwitchAndInactivePageCompleteOnlyFinalActiveTarget() async {
        let sessionA = "agent:main:clawline:user:s_t1738_rapid_a"
        let sessionB = "agent:main:clawline:user:s_t1738_rapid_b"
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: TestChatService(),
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: UploadService(auth: auth),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.prepareForReplacement() }
        let controller = MessageFlowCollectionViewController(nibName: nil, bundle: nil)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 700)

        viewModel.requestCrossChatNotificationNavigation(to: sessionA)
        update(controller, with: viewModel, sessionKey: sessionA, isActiveSession: true)
        let sequenceBeforeRapidSwitch = viewModel.engineActivationCompletedSequence

        viewModel.requestCrossChatNotificationNavigation(to: sessionB)
        viewModel.requestStreamSwitch(to: sessionA, source: .programmatic)
        update(controller, with: viewModel, sessionKey: sessionB, isActiveSession: true)
        await Task.yield()
        #expect(viewModel.engineActivationCompletedSequence == sequenceBeforeRapidSwitch)
        update(controller, with: viewModel, sessionKey: sessionA, isActiveSession: false)
        await Task.yield()
        #expect(viewModel.engineActivationCompletedSequence == sequenceBeforeRapidSwitch)
        update(controller, with: viewModel, sessionKey: sessionA, isActiveSession: true)
        await Task.yield()
        #expect(viewModel.engineActivationCompletedSequence == sequenceBeforeRapidSwitch + 1)

        controller.scrollToTop(animated: false)
        controller.scrollToBottom(animated: false)
        update(controller, with: viewModel, sessionKey: sessionA, isActiveSession: true)
        #expect(viewModel.engineActivationCompletedSequence == sequenceBeforeRapidSwitch + 1)
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
