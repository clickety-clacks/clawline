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

    @Test("T320: corner indicators stay Spatial-only")
    func cornerIndicatorsStaySpatialOnly() throws {
        let appPath = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Clawline/ClawlineApp.swift")
        let appSource = try String(contentsOf: appPath, encoding: .utf8)
        #expect(!appSource.contains("ClawlineWindowCornerIndicators"))

        let spatialAppPath = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Clawline Spatial/Clawline_SpatialApp.swift")
        let spatialAppSource = try String(contentsOf: spatialAppPath, encoding: .utf8)
        #expect(spatialAppSource.contains("ClawlineWindowCornerIndicators"))
    }

    @Test("T294: Spatial typing indicator exposes a concrete tap control")
    func spatialTypingIndicatorHasConcreteTapControl() throws {
        let sourcePath = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Clawline/Views/Chat/TypingIndicatorCell.swift")
        let source = try String(contentsOf: sourcePath, encoding: .utf8)
        let pattern = #"(?s)#if os\(visionOS\).*?spatialTapButton.*?UIButton\(type: \.custom\).*?addTarget\(self, action: #selector\(handleTap\), for: \.primaryActionTriggered\).*?#endif"#
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
            sonioxKeyStore: SonioxKeyStore(),
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
        #expect(chatService.connectCalls == 0)
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

    @Test("Settings Soniox key source is shared with Watch credential bridge")
    @MainActor
    func settingsSonioxKeySourceFeedsWatchCredentialBridge() async {
        let defaults = UserDefaults.standard
        let previousKey = defaults.object(forKey: "soniox.apiKey")
        let previousStatus = defaults.object(forKey: "soniox.apiKeyStatus")
        let previousProviderURL = ProviderBaseURLStore.baseURL
        defaults.removeObject(forKey: "soniox.apiKey")
        defaults.removeObject(forKey: "soniox.apiKeyStatus")
        ProviderBaseURLStore.clearBaseURL()
        defer {
            if let previousKey {
                defaults.set(previousKey, forKey: "soniox.apiKey")
            } else {
                defaults.removeObject(forKey: "soniox.apiKey")
            }
            if let previousStatus {
                defaults.set(previousStatus, forKey: "soniox.apiKeyStatus")
            } else {
                defaults.removeObject(forKey: "soniox.apiKeyStatus")
            }
            if let previousProviderURL {
                ProviderBaseURLStore.setBaseURL(previousProviderURL)
            } else {
                ProviderBaseURLStore.clearBaseURL()
            }
        }

        let sonioxKeyStore = SonioxKeyStore(verifier: AcceptingSonioxKeyVerifier())
        let settings = SettingsManager(
            sonioxKeyStore: sonioxKeyStore,
            cartesiaKeyStore: CartesiaKeyStore(keychain: KeychainSecureStore(service: "ClawlineTests.sonioxSettings.\(UUID().uuidString)"))
        )
        settings.sonioxAPIKey = "  iphone-soniox-key  "

        let suiteName = "ClawlineTests.sonioxWatchBridge"
        let authDefaults = UserDefaults(suiteName: suiteName) ?? .standard
        authDefaults.removePersistentDomain(forName: suiteName)
        defer { authDefaults.removePersistentDomain(forName: suiteName) }
        let authManager = AuthManager(storage: authDefaults, secureStore: InMemorySecureStore())
        authManager.storeCredentials(token: "jwt", userId: "user")
        let service = WatchConnectivityService(
            authManager: authManager,
            sonioxKeyStore: sonioxKeyStore,
            cartesiaKeyStore: CartesiaKeyStore(keychain: KeychainSecureStore()),
            chatService: SpyChatService()
        )

        let reply = await service.handleTestMessage([
            "type": "auth.refresh",
            "requestId": "req-soniox"
        ])
        let payload = reply["payload"] as? [String: Any]

        #expect(SonioxConfigurationStore.apiKey == "iphone-soniox-key")
        #expect(sonioxKeyStore.keyForCredentialSync == "iphone-soniox-key")
        #expect(payload?["sonioxApiKey"] as? String == "iphone-soniox-key")

        settings.sonioxAPIKey = " "
        let clearedReply = await service.handleTestMessage([
            "type": "auth.refresh",
            "requestId": "req-soniox-clear"
        ])
        let clearedPayload = clearedReply["payload"] as? [String: Any]

        #expect(SonioxConfigurationStore.apiKey == nil)
        #expect(sonioxKeyStore.keyForCredentialSync == nil)
        #expect(clearedPayload?["sonioxApiKey"] as? String == "")
    }

    @Test("Settings Cartesia key source is shared with Watch credential bridge")
    @MainActor
    func settingsCartesiaKeySourceFeedsWatchCredentialBridge() async {
        let sonioxKeyStore = SonioxKeyStore(verifier: AcceptingSonioxKeyVerifier())
        let cartesiaKeyStore = CartesiaKeyStore(keychain: KeychainSecureStore(service: "ClawlineTests.cartesiaSettings.\(UUID().uuidString)"))
        let settings = SettingsManager(sonioxKeyStore: sonioxKeyStore, cartesiaKeyStore: cartesiaKeyStore)
        settings.cartesiaAPIKey = "  iphone-cartesia-key  "
        settings.cartesiaVoiceId = "  sonic-voice  "

        let suiteName = "ClawlineTests.cartesiaWatchBridge"
        let authDefaults = UserDefaults(suiteName: suiteName) ?? .standard
        authDefaults.removePersistentDomain(forName: suiteName)
        defer { authDefaults.removePersistentDomain(forName: suiteName) }
        let authManager = AuthManager(storage: authDefaults, secureStore: InMemorySecureStore())
        authManager.storeCredentials(token: "jwt", userId: "user")
        let service = WatchConnectivityService(
            authManager: authManager,
            sonioxKeyStore: sonioxKeyStore,
            cartesiaKeyStore: cartesiaKeyStore,
            chatService: SpyChatService()
        )

        let reply = await service.handleTestMessage([
            "type": "auth.refresh",
            "requestId": "req-cartesia"
        ])
        let payload = reply["payload"] as? [String: Any]

        #expect(cartesiaKeyStore.apiKeyForCredentialSync == "iphone-cartesia-key")
        #expect(cartesiaKeyStore.voiceIdForCredentialSync == "sonic-voice")
        #expect(payload?["cartesiaApiKey"] as? String == "iphone-cartesia-key")
        #expect(payload?["cartesiaVoiceId"] as? String == "sonic-voice")

        settings.cartesiaAPIKey = " "
        settings.cartesiaVoiceId = ""
        let clearedReply = await service.handleTestMessage([
            "type": "auth.refresh",
            "requestId": "req-cartesia-clear"
        ])
        let clearedPayload = clearedReply["payload"] as? [String: Any]

        #expect(cartesiaKeyStore.apiKeyForCredentialSync == nil)
        #expect(cartesiaKeyStore.voiceIdForCredentialSync == nil)
        #expect(clearedPayload?["cartesiaApiKey"] as? String == "")
        #expect(clearedPayload?["cartesiaVoiceId"] as? String == "")
    }

    @Test("Soniox key clear is included in Watch credential push without provider auth")
    @MainActor
    func credentialClearPushDoesNotRequireProviderAuthAndIncludesAllClearFields() {
        let defaults = UserDefaults.standard
        let previousKey = defaults.object(forKey: "soniox.apiKey")
        let previousStatus = defaults.object(forKey: "soniox.apiKeyStatus")
        let previousProviderURL = ProviderBaseURLStore.baseURL
        defaults.removeObject(forKey: "soniox.apiKey")
        defaults.removeObject(forKey: "soniox.apiKeyStatus")
        ProviderBaseURLStore.clearBaseURL()
        defer {
            if let previousKey {
                defaults.set(previousKey, forKey: "soniox.apiKey")
            } else {
                defaults.removeObject(forKey: "soniox.apiKey")
            }
            if let previousStatus {
                defaults.set(previousStatus, forKey: "soniox.apiKeyStatus")
            } else {
                defaults.removeObject(forKey: "soniox.apiKeyStatus")
            }
            if let previousProviderURL {
                ProviderBaseURLStore.setBaseURL(previousProviderURL)
            } else {
                ProviderBaseURLStore.clearBaseURL()
            }
        }

        let sonioxKeyStore = SonioxKeyStore(verifier: AcceptingSonioxKeyVerifier())
        sonioxKeyStore.setKey(" ")
        let authDefaults = UserDefaults(suiteName: "ClawlineTests.sonioxClearNoAuth") ?? .standard
        authDefaults.removePersistentDomain(forName: "ClawlineTests.sonioxClearNoAuth")
        defer { authDefaults.removePersistentDomain(forName: "ClawlineTests.sonioxClearNoAuth") }
        let service = WatchConnectivityService(
            authManager: AuthManager(storage: authDefaults, secureStore: InMemorySecureStore()),
            sonioxKeyStore: sonioxKeyStore,
            cartesiaKeyStore: CartesiaKeyStore(keychain: KeychainSecureStore()),
            chatService: SpyChatService()
        )

        let payload = service.makeCredentialPushPayload(pushedAt: 123)

        #expect(payload["type"] as? String == "credential_push")
        #expect(payload["pushedAt"] as? TimeInterval == 123)
        #expect(payload["sonioxApiKey"] as? String == "")
        #expect(payload["cartesiaApiKey"] as? String == "")
        #expect(payload["cartesiaVoiceId"] as? String == "")
        #expect(payload["token"] as? String == "")
        #expect(payload["userId"] as? String == "")
        #expect(payload["providerBaseURL"] is String)
        #expect(PropertyListSerialization.propertyList(payload, isValidFor: .binary))
    }

    @Test("Watch credential push explicitly clears provider URL when none is configured")
    func watchCredentialPayloadContainsProviderURLClearSemantic() throws {
        let bridgePath = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Clawline/Services/WatchConnectivityService.swift")
        let bridgeSource = try String(contentsOf: bridgePath, encoding: .utf8)

        #expect(bridgeSource.contains(#""providerBaseURL": ProviderBaseURLStore.baseURL?.absoluteString ?? """#))
    }

    @Test("Clawline app wires one Soniox store into Settings and Watch connectivity")
    func clawlineAppSharesSonioxStoreBetweenSettingsAndWatchBridge() throws {
        let appPath = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Clawline/ClawlineApp.swift")
        let appSource = try String(contentsOf: appPath, encoding: .utf8)
        let bridgePath = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Clawline/Services/WatchConnectivityService.swift")
        let bridgeSource = try String(contentsOf: bridgePath, encoding: .utf8)

        #expect(appSource.contains("let sonioxKeyStore = SonioxKeyStore()"))
        #expect(appSource.contains("SettingsManager(sonioxKeyStore: sonioxKeyStore, cartesiaKeyStore: cartesiaKeyStore)"))
        #expect(appSource.contains("sonioxKeyStore: sonioxKeyStore"))
        #expect(bridgeSource.contains("sonioxKeyStore.keyForCredentialSync"))
    }

    @Test("Clawline app wires one Cartesia store into Settings and Watch connectivity")
    func clawlineAppSharesCartesiaStoreBetweenSettingsAndWatchBridge() throws {
        let appPath = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Clawline/ClawlineApp.swift")
        let appSource = try String(contentsOf: appPath, encoding: .utf8)
        let bridgePath = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Clawline/Services/WatchConnectivityService.swift")
        let bridgeSource = try String(contentsOf: bridgePath, encoding: .utf8)

        #expect(appSource.contains("let cartesiaKeyStore = CartesiaKeyStore"))
        #expect(appSource.contains("SettingsManager(sonioxKeyStore: sonioxKeyStore, cartesiaKeyStore: cartesiaKeyStore)"))
        #expect(appSource.contains("cartesiaKeyStore: cartesiaKeyStore"))
        #expect(bridgeSource.contains("cartesiaKeyStore.apiKeyForCredentialSync"))
        #expect(bridgeSource.contains("cartesiaKeyStore.voiceIdForCredentialSync"))
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

    @Test("watch relay chat.send connects phone transport before dispatch when needed")
    @MainActor
    func watchRelayChatSendReconnectsBeforeDispatchWhenPhoneTransportIsDown() async {
        let suiteName = "ClawlineTests.watchRelayChatSendReconnects"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let chatService = SpyChatService()
        chatService.isReadyForSend = false
        let authManager = AuthManager(storage: defaults, secureStore: InMemorySecureStore())
        authManager.storeCredentials(token: "jwt", userId: "user")
        let service = WatchConnectivityService(
            authManager: authManager,
            sonioxKeyStore: SonioxKeyStore(),
            cartesiaKeyStore: CartesiaKeyStore(keychain: KeychainSecureStore()),
            chatService: chatService
        )

        let reply = await service.handleTestMessage([
            "type": "chat.send",
            "requestId": "req-2",
            "payload": [
                "id": "msg-2",
                "content": "relay after reconnect",
                "sessionKey": "agent:main:clawline:flynn:main",
                "attachments": []
            ]
        ])

        #expect(reply["type"] as? String == "chat.send.ack")
        #expect(chatService.connectCalls == 1)
        #expect(chatService.connectTokens == ["jwt"])
        #expect(chatService.sentMessages.map(\.id) == ["msg-2"])
    }

    @Test("watch relay chat.send fails before dispatch if reconnect does not produce a send-ready transport")
    @MainActor
    func watchRelayChatSendDoesNotDispatchWhenReconnectIsStillNotReady() async {
        let suiteName = "ClawlineTests.watchRelayChatSendReconnectStillNotReady"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let chatService = SpyChatService()
        chatService.isReadyForSend = false
        chatService.markReadyOnConnect = false
        let authManager = AuthManager(storage: defaults, secureStore: InMemorySecureStore())
        authManager.storeCredentials(token: "jwt", userId: "user")
        let service = WatchConnectivityService(
            authManager: authManager,
            sonioxKeyStore: SonioxKeyStore(),
            cartesiaKeyStore: CartesiaKeyStore(keychain: KeychainSecureStore()),
            chatService: chatService
        )

        let reply = await service.handleTestMessage([
            "type": "chat.send",
            "requestId": "req-3",
            "payload": [
                "id": "msg-3",
                "content": "relay while connecting",
                "sessionKey": "agent:main:clawline:flynn:main",
                "attachments": []
            ]
        ])

        let error = reply["error"] as? [String: Any]
        #expect(error?["code"] as? String == "not_connected")
        #expect(chatService.connectCalls == 1)
        #expect(chatService.sentMessages.isEmpty)
    }

    @Test("watch relay chat.send does not start a direct connect for lifecycle-managed transport")
    @MainActor
    func watchRelayChatSendDoesNotStartDirectConnectForLifecycleManagedTransport() async {
        let suiteName = "ClawlineTests.watchRelayChatSendLifecycleManaged"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let chatService = SpyChatService()
        chatService.isReadyForSend = false
        chatService.allowsDirectRelayTransportConnect = false
        let authManager = AuthManager(storage: defaults, secureStore: InMemorySecureStore())
        authManager.storeCredentials(token: "jwt", userId: "user")
        let service = WatchConnectivityService(
            authManager: authManager,
            sonioxKeyStore: SonioxKeyStore(),
            cartesiaKeyStore: CartesiaKeyStore(keychain: KeychainSecureStore()),
            chatService: chatService
        )

        let reply = await service.handleTestMessage([
            "type": "chat.send",
            "requestId": "req-4",
            "payload": [
                "id": "msg-4",
                "content": "relay through lifecycle",
                "sessionKey": "agent:main:clawline:flynn:main",
                "attachments": []
            ]
        ])

        let error = reply["error"] as? [String: Any]
        #expect(error?["code"] as? String == "not_connected")
        #expect(chatService.connectCalls == 0)
        #expect(chatService.sentMessages.isEmpty)
    }

    @Test("Siri send intent opens provider transport through lifecycle coordinator")
    func siriSendIntentOpensProviderTransportThroughLifecycleCoordinator() throws {
        let intentPath = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Clawline/Intents/SiriSendMessageIntent.swift")
        let source = try String(contentsOf: intentPath, encoding: .utf8)
        let connectRange = try #require(source.range(of: "private func connectSiriChatTransportWithLifecycle"))
        let performRange = try #require(source.range(of: "func perform()"))
        let performBody = source[performRange.lowerBound..<connectRange.lowerBound]
        let connectBody = source[connectRange.lowerBound..<source.endIndex]

        #expect(performBody.contains("connectSiriChatTransportWithLifecycle"))
        #expect(!performBody.contains("chatService.connect(token:"))
        #expect(connectBody.contains("ConnectionLifecycleCoordinator"))
        #expect(connectBody.contains("startConnectionAttempt(epoch:"))
        #expect(connectBody.contains("setLifecycleTransportReadyForSend(to == .live"))
    }

}

struct T100ConnectionLifecycleCoordinatorTests {
    @Test("T100: replay requires active sync completion before live")
    func replayRequiresActiveSyncCompletionBeforeLive() async {
        let starts = T100LifecycleStartRecorder()
        let coordinator = ConnectionLifecycleCoordinator(
            startAttempt: { epoch, lastMessageId, token in
                Task { await starts.record(epoch: epoch, lastMessageId: lastMessageId, token: token) }
            },
            stopAttempt: {},
            randomJitterMs: { 0 }
        )
        let outputs = T100LifecycleOutputRecorder()
        let outputStream = await coordinator.outputs
        let outputTask = Task {
            for await output in outputStream {
                await outputs.record(output)
            }
        }
        defer { outputTask.cancel() }

        await coordinator.viewAppeared()
        await coordinator.authChanged(token: "jwt")
        #expect(await t100WaitUntil { await starts.count() == 1 })

        await coordinator.handleTransportEvent(.init(epoch: 1, payload: .transportOpened))
        await coordinator.handleTransportEvent(.init(
            epoch: 1,
            payload: .authResult(
                success: true,
                replayCount: 0,
                replayTruncated: false,
                historyReset: false,
                failureReason: nil
            )
        ))
        #expect(await t100WaitUntil { await coordinator.phase == .replaying })

        await coordinator.handleTransportEvent(.init(epoch: 0, payload: .syncComplete))
        try? await Task.sleep(forDuration: .milliseconds(30))
        #expect(await coordinator.phase == .replaying)

        await coordinator.handleTransportEvent(.init(epoch: 1, payload: .syncComplete))
        #expect(await t100WaitUntil { await coordinator.phase == .live })
        #expect(await outputs.transitionTargets() == [.connecting, .authenticating, .replaying, .live])
    }

    @Test("T100: stale epoch output cannot advance a newer attempt")
    func staleEpochOutputCannotAdvanceNewerAttempt() async {
        let starts = T100LifecycleStartRecorder()
        let coordinator = ConnectionLifecycleCoordinator(
            startAttempt: { epoch, lastMessageId, token in
                Task { await starts.record(epoch: epoch, lastMessageId: lastMessageId, token: token) }
            },
            stopAttempt: {},
            randomJitterMs: { 0 }
        )

        await coordinator.viewAppeared()
        await coordinator.authChanged(token: "jwt")
        #expect(await t100WaitUntil { await starts.count() == 1 })
        await coordinator.handleTransportEvent(.init(epoch: 1, payload: .transportOpened))
        await coordinator.handleTransportEvent(.init(
            epoch: 1,
            payload: .authResult(
                success: true,
                replayCount: 0,
                replayTruncated: false,
                historyReset: false,
                failureReason: nil
            )
        ))
        #expect(await t100WaitUntil { await coordinator.phase == .replaying })

        await coordinator.disconnectRequested()
        await coordinator.startIfNeeded()
        #expect(await t100WaitUntil { await starts.count() == 2 })

        await coordinator.handleTransportEvent(.init(epoch: 1, payload: .syncComplete))
        await coordinator.handleTransportEvent(.init(
            epoch: 1,
            payload: .authResult(
                success: true,
                replayCount: 0,
                replayTruncated: false,
                historyReset: false,
                failureReason: nil
            )
        ))
        try? await Task.sleep(forDuration: .milliseconds(30))
        #expect(await coordinator.phase == .connecting)

        await coordinator.handleTransportEvent(.init(epoch: 2, payload: .transportOpened))
        await coordinator.handleTransportEvent(.init(
            epoch: 2,
            payload: .authResult(
                success: true,
                replayCount: 0,
                replayTruncated: false,
                historyReset: false,
                failureReason: nil
            )
        ))
        await coordinator.handleTransportEvent(.init(epoch: 2, payload: .syncComplete))
        #expect(await t100WaitUntil { await coordinator.phase == .live })
    }

    @Test("T100: recovering ignores late auth success and manual retry cancels backoff")
    func recoveringIgnoresLateAuthSuccessAndManualRetryCancelsBackoff() async {
        let starts = T100LifecycleStartRecorder()
        let coordinator = ConnectionLifecycleCoordinator(
            startAttempt: { epoch, lastMessageId, token in
                Task { await starts.record(epoch: epoch, lastMessageId: lastMessageId, token: token) }
            },
            stopAttempt: {},
            randomJitterMs: { 0 }
        )
        let outputs = T100LifecycleOutputRecorder()
        let outputStream = await coordinator.outputs
        let outputTask = Task {
            for await output in outputStream {
                await outputs.record(output)
            }
        }
        defer { outputTask.cancel() }

        await coordinator.viewAppeared()
        await coordinator.authChanged(token: "jwt")
        #expect(await t100WaitUntil { await starts.count() == 1 })
        await coordinator.handleTransportEvent(.init(epoch: 1, payload: .transportOpened))
        await coordinator.handleTransportEvent(.init(epoch: 1, payload: .transportTimeout))
        #expect(await t100WaitUntil { await coordinator.phase == .recovering })

        await coordinator.handleTransportEvent(.init(
            epoch: 1,
            payload: .authResult(
                success: true,
                replayCount: 0,
                replayTruncated: false,
                historyReset: false,
                failureReason: nil
            )
        ))
        try? await Task.sleep(forDuration: .milliseconds(30))
        #expect(await coordinator.phase == .recovering)
        #expect(await outputs.containsTransition(from: .recovering, to: .authenticating) == false)

        await coordinator.manualRetry()
        #expect(await t100WaitUntil { await starts.count() == 2 })
        #expect(await coordinator.phase == .connecting)

        try? await Task.sleep(forDuration: .milliseconds(1100))
        #expect(await starts.count() == 2)
    }
}

private actor T100LifecycleStartRecorder {
    private var calls: [(epoch: Int, lastMessageId: String?, token: String)] = []

    func record(epoch: Int, lastMessageId: String?, token: String) {
        calls.append((epoch, lastMessageId, token))
    }

    func count() -> Int {
        calls.count
    }
}

private actor T100LifecycleOutputRecorder {
    private var outputs: [ConnectionLifecycleOutput] = []

    func record(_ output: ConnectionLifecycleOutput) {
        outputs.append(output)
    }

    func transitionTargets() -> [ConnectionLifecyclePhase] {
        outputs.compactMap { output in
            guard case .phaseTransition(_, let to, _, _) = output else { return nil }
            return to
        }
    }

    func containsTransition(from expectedFrom: ConnectionLifecyclePhase, to expectedTo: ConnectionLifecyclePhase) -> Bool {
        outputs.contains { output in
            guard case .phaseTransition(let from, let to, _, _) = output else { return false }
            return from == expectedFrom && to == expectedTo
        }
    }
}

private func t100WaitUntil(_ condition: @escaping @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<80 {
        if await condition() {
            return true
        }
        try? await Task.sleep(forDuration: .milliseconds(10))
    }
    return await condition()
}

private final class SpyChatService: ChatServicing {
    struct SentMessage {
        let id: String
        let content: String
        let attachments: [WireAttachment]
        let sessionKey: String?
    }

    private(set) var sentMessages: [SentMessage] = []
    private(set) var connectCalls = 0
    private(set) var connectTokens: [String] = []
    var isReadyForSend = true
    var markReadyOnConnect = true
    var allowsDirectRelayTransportConnect = true

    let incomingMessages = AsyncStream<Message> { _ in }
    let connectionState = AsyncStream<ConnectionState> { continuation in continuation.yield(.connected) }
    let serviceEvents = AsyncStream<ChatServiceEvent> { _ in }
    let lifecycleTransportEvents = AsyncStream<LifecycleTransportEvent> { _ in }
    var isTransportReadyForSend: Bool { isReadyForSend }

    func connect(token: String, lastMessageId: String?) async throws {
        connectCalls += 1
        connectTokens.append(token)
        if markReadyOnConnect {
            isReadyForSend = true
        }
    }
    func startConnectionAttempt(epoch: Int, lastMessageId: String?, token: String) {}
    func stopConnectionAttempt() {}
    func disconnect() {}
    func replayCursorSnapshot() -> [String : String] { [:] }
    func setReplayCursor(_ cursor: String?, for sessionKey: String) {}
    func seedReplayCursorIfMissing(_ cursor: String?, for sessionKey: String) {}
    func clearReplayCursors() {}
    func send(
        id: String,
        content: String,
        attachments: [WireAttachment],
        sessionKey: String?,
        references: [MessageReferenceContext]
    ) async throws {
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

private final class AcceptingSonioxKeyVerifier: SonioxKeyVerifying {
    func verify(apiKey: String) async -> Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

private final class InMemorySecureStore: SecureStoring {
    private var storage: [String: String] = [:]
    func setString(_ value: String, forKey key: String) { storage[key] = value }
    func getString(_ key: String) -> String? { storage[key] }
    func removeValue(forKey key: String) { storage.removeValue(forKey: key) }
}
