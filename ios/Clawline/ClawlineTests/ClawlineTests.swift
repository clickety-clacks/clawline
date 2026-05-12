//
//  ClawlineTests.swift
//  ClawlineTests
//
//  Created by Mike Manzano on 1/7/26.
//

import Foundation
import Testing
@testable import Clawline

struct ClawlineTests {
    @Test("T167: font scale applies platform delta before user multiplier")
    func scaledPointSizeUsesPlatformDeltaAndPersistedScale() {
        let suiteName = "ClawlineTests.T167.scaledPointSizeUsesPlatformDeltaAndPersistedScale"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("Failed to create isolated defaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let basePointSize: CGFloat = 20
        let expectedDefault: CGFloat
#if targetEnvironment(macCatalyst)
        expectedDefault = 24
#else
        expectedDefault = 20
#endif

        #expect(AppFontScale.scaledPointSize(for: basePointSize, defaults: defaults) == expectedDefault)

        AppFontScale.persist(1.5, defaults: defaults)
        #expect(
            AppFontScale.scaledPointSize(for: basePointSize, defaults: defaults)
                == expectedDefault * 1.5
        )
    }

    @Test("T134: font scale shortcuts adjust value and emit toast message")
    @MainActor
    func fontScaleAdjustmentsEmitToast() {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: AppFontScale.storageKey)
        defer {
            if let previous {
                defaults.set(previous, forKey: AppFontScale.storageKey)
            } else {
                defaults.removeObject(forKey: AppFontScale.storageKey)
            }
            AppFontScale.useActiveValue(AppFontScale.persistedValue())
        }
        defaults.removeObject(forKey: AppFontScale.storageKey)

        let settings = SettingsManager()
        #expect(settings.fontScale == AppFontScale.defaultValue)
        #expect(AppFontScale.currentValue() == settings.fontScale)

        settings.increaseFontScale()
        #expect(settings.fontScale == AppFontScale.defaultValue + AppFontScale.step)
        #expect(AppFontScale.currentValue() == settings.fontScale)
        #expect(settings.consumePendingFontScaleToastMessage() == "Font scale 110%")

        settings.decreaseFontScale()
        #expect(settings.fontScale == AppFontScale.defaultValue)
        #expect(AppFontScale.currentValue() == settings.fontScale)
        #expect(settings.consumePendingFontScaleToastMessage() == "Font scale 100%")
    }

    @Test("T134: app font scale clamps at configured limits")
    @MainActor
    func fontScaleClampsToBounds() {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: AppFontScale.storageKey)
        defer {
            if let previous {
                defaults.set(previous, forKey: AppFontScale.storageKey)
            } else {
                defaults.removeObject(forKey: AppFontScale.storageKey)
            }
            AppFontScale.useActiveValue(AppFontScale.persistedValue())
        }
        defaults.removeObject(forKey: AppFontScale.storageKey)

        let settings = SettingsManager()

        for _ in 0..<30 {
            settings.increaseFontScale()
        }
        #expect(settings.fontScale == AppFontScale.maximum)
        #expect(AppFontScale.currentValue() == AppFontScale.maximum)

        for _ in 0..<60 {
            settings.decreaseFontScale()
        }
        #expect(settings.fontScale == AppFontScale.minimum)
        #expect(AppFontScale.currentValue() == AppFontScale.minimum)
    }

    @Test("T180: placeholder text includes channel name and session key")
    func placeholderTextIncludesSessionKey() {
        #expect(
            ChatViewModel.placeholderText(
                displayName: "Main",
                sessionKey: "agent:main:clawline:flynn:main"
            ) == "Main — agent:main:clawline:flynn:main"
        )
        #expect(ChatViewModel.placeholderText(displayName: "Main", sessionKey: "") == "Main")
    }

    @Test("T001: Clawline personal terminal streams allow built-in and custom suffixes")
    func sessionKeyAllowsPersonalTerminalStreamSuffixes() {
        #expect(SessionKey.isClawlinePersonalDM("agent:main:clawline:flynn:main"))
        #expect(SessionKey.isClawlinePersonalDM("agent:main:clawline:flynn:dm"))
        #expect(SessionKey.isClawlinePersonalDM("agent:main:clawline:flynn:s_abcd1234"))
        #expect(SessionKey.isClawlinePersonalDM("agent:aux:clawline:flynn:s_abcd1234"))
    }

    @Test("T001: Clawline personal terminal streams reject invalid suffixes")
    func sessionKeyRejectsInvalidPersonalTerminalStreamSuffixes() {
        #expect(!SessionKey.isClawlinePersonalDM("agent:main:clawline:flynn:global_dm"))
        #expect(!SessionKey.isClawlinePersonalDM("agent:main:clawline:flynn:s_deadbee"))
        #expect(!SessionKey.isClawlinePersonalDM("agent:main:clawline:flynn:s_deadbeez"))
        #expect(!SessionKey.isClawlinePersonalDM("agent:main:clawline::main"))
        #expect(!SessionKey.isClawlinePersonalDM("server:main"))
    }

    @Test("T201: RootView keeps iOS system-follow by scoping preferredColorScheme to visionOS")
    func rootViewScopesPreferredColorSchemeToVisionOS() throws {
        let rootViewPath = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Clawline/Views/RootView.swift")
        let source = try String(contentsOf: rootViewPath, encoding: .utf8)
        let pattern = #"#if os\(visionOS\)[\s\S]*?\.preferredColorScheme\(settings\.preferredColorScheme\)[\s\S]*?#endif"#
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        let regex = try NSRegularExpression(pattern: pattern)

        #expect(regex.firstMatch(in: source, range: range) != nil)
    }

    @Test("T219: pairing shader is active only while pairing route is visible")
    func rootBackgroundShaderLifecycleFollowsPairingRoute() {
        #expect(RootBackgroundShaderLifecycle.isShaderActive(
            isAuthenticated: false,
            isProviderConfigured: false
        ))
        #expect(RootBackgroundShaderLifecycle.isShaderActive(
            isAuthenticated: false,
            isProviderConfigured: true
        ))
        #expect(RootBackgroundShaderLifecycle.isShaderActive(
            isAuthenticated: true,
            isProviderConfigured: false
        ))
        #expect(!RootBackgroundShaderLifecycle.isShaderActive(
            isAuthenticated: true,
            isProviderConfigured: true
        ))
    }

    @Test("watch relay chat.send is dispatched through the iPhone relay service")
    @MainActor
    func watchRelayChatSendDispatchesThroughPhoneService() async {
        let suiteName = "ClawlineTests.watchRelayChatSend"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let chatService = SpyChatService()
        let authManager = AuthManager(storage: defaults, secureStore: InMemorySecureStore())
        let service = WatchConnectivityService(
            authManager: authManager,
            sonioxKeyStore: SonioxKeyStore(keychain: KeychainSecureStore()),
            cartesiaKeyStore: CartesiaKeyStore(keychain: KeychainSecureStore()),
            chatService: chatService
        )

        let reply = await service.handleTestMessage([
            "type": "chat.send",
            "requestId": "req-1",
            "payload": [
                "id": "msg-1",
                "content": "hello from watch",
                "sessionKey": "agent:main:clawline:flynn:main",
                "attachments": []
            ]
        ])

        #expect(reply["type"] as? String == "chat.send.ack")
        #expect(chatService.sentMessages.count == 1)
        #expect(chatService.sentMessages.first?.id == "msg-1")
        #expect(chatService.sentMessages.first?.content == "hello from watch")
        #expect(chatService.sentMessages.first?.sessionKey == "agent:main:clawline:flynn:main")
    }

    @Test("Clawline app retains and activates the watch connectivity service")
    func clawlineAppRetainsAndActivatesWatchConnectivityService() throws {
        let appPath = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Clawline/ClawlineApp.swift")
        let source = try String(contentsOf: appPath, encoding: .utf8)
        #expect(source.contains("@State private var watchConnectivityService: WatchConnectivityService"))
        #expect(source.contains("watchConnectivityService.activate()"))
    }


    @Test("watch relay chat.send activates relay observation before dispatch")
    func watchRelayChatSendActivatesRelayBeforeDispatch() throws {
        let servicePath = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Clawline/Services/WatchConnectivityService.swift")
        let source = try String(contentsOf: servicePath, encoding: .utf8)
        let chatSendRange = try #require(source.range(of: "private func handleChatSend"))
        let dispatchRange = try #require(source.range(of: "try await chatService.send", range: chatSendRange.lowerBound..<source.endIndex))
        let bodyBeforeDispatch = source[chatSendRange.lowerBound..<dispatchRange.lowerBound]

        #expect(bodyBeforeDispatch.contains("activateRelay()"))
    }

}

private final class SpyChatService: ChatServicing {
    struct SentMessage {
        let id: String
        let content: String
        let attachments: [WireAttachment]
        let sessionKey: String?
    }

    private(set) var sentMessages: [SentMessage] = []

    let incomingMessages = AsyncStream<Message> { _ in }
    let connectionState = AsyncStream<ConnectionState> { continuation in continuation.yield(.connected) }
    let serviceEvents = AsyncStream<ChatServiceEvent> { _ in }
    let lifecycleTransportEvents = AsyncStream<LifecycleTransportEvent> { _ in }
    let isTransportReadyForSend = true

    func connect(token: String, lastMessageId: String?) async throws {}
    func startConnectionAttempt(epoch: Int, lastMessageId: String?, token: String) {}
    func stopConnectionAttempt() {}
    func disconnect() {}
    func replayCursorSnapshot() -> [String : String] { [:] }
    func setReplayCursor(_ cursor: String?, for sessionKey: String) {}
    func seedReplayCursorIfMissing(_ cursor: String?, for sessionKey: String) {}
    func clearReplayCursors() {}
    func send(id: String, content: String, attachments: [WireAttachment], sessionKey: String?) async throws {
        sentMessages.append(SentMessage(id: id, content: content, attachments: attachments, sessionKey: sessionKey))
    }
    func sendInteractiveCallback(sourceMessageId: String, action: String, data: JSONValue?) async throws {}
    func publishReadState(sessionKey: String, lastReadMessageId: String) async throws {}
    func fetchStreams() async throws -> [StreamSession] { [] }
    func fetchTrackableSessions() async throws -> [TrackableSession] { [] }
    func fetchSessionStatus(sessionKey: String) async throws -> SessionStatus { fatalError() }
    func applySessionControl(sessionKey: String, action: SessionControlAction, value: String?, enabled: Bool?) async throws -> SessionControlResponse { fatalError() }
    func adoptStream(sessionKey: String) async throws -> StreamSession { fatalError() }
    func createStream(displayName: String, idempotencyKey: String) async throws -> StreamSession { fatalError() }
    func renameStream(sessionKey: String, displayName: String) async throws -> StreamSession { fatalError() }
    func deleteStream(sessionKey: String, idempotencyKey: String?) async throws -> String { fatalError() }
}

private final class InMemorySecureStore: SecureStoring {
    private var storage: [String: String] = [:]
    func setString(_ value: String, forKey key: String) { storage[key] = value }
    func getString(_ key: String) -> String? { storage[key] }
    func removeValue(forKey key: String) { storage.removeValue(forKey: key) }
}
