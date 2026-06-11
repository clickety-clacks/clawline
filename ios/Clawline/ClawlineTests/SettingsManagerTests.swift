import Foundation
import Testing
@testable import Clawline

@MainActor
struct SettingsManagerTests {
    @Test("CTA label is Get Key when empty and Verify when key is present")
    func ctaLabelSwitchesWithKeyPresence() {
        resetSonioxDefaultsForTest()
        defer { resetSonioxDefaultsForTest() }

        let manager = makeSettingsManager(sonioxVerifier: MockSettingsKeyVerifier())
        manager.sonioxAPIKey = ""
        #expect(manager.sonioxCTATitle == "Get Key")

        manager.sonioxAPIKey = "test-key"
        #expect(manager.sonioxCTATitle == "Verify")
        #expect(manager.sonioxKeyStatus == .unverified)
    }

    @Test("Empty key primary action opens Soniox key page and remains missing")
    func emptyKeyPrimaryActionOpensManagePage() async {
        resetSonioxDefaultsForTest()
        defer { resetSonioxDefaultsForTest() }

        let manager = makeSettingsManager(sonioxVerifier: MockSettingsKeyVerifier())
        manager.sonioxAPIKey = ""

        var openedURL: URL?
        let result = await manager.handleSonioxPrimaryAction { url in
            openedURL = url
        }

        #expect(!result)
        #expect(openedURL == SonioxConfigurationStore.keyManagementURL)
        #expect(manager.sonioxKeyStatus == .missing)
    }

    @Test("Verify success sets Validated status")
    func verifySuccessSetsValidated() async {
        resetSonioxDefaultsForTest()
        defer { resetSonioxDefaultsForTest() }

        let verifier = MockSettingsKeyVerifier(results: [true])
        let manager = makeSettingsManager(sonioxVerifier: verifier)
        manager.sonioxAPIKey = "valid-key"

        let result = await manager.handleSonioxPrimaryAction { _ in }

        #expect(result)
        #expect(manager.sonioxKeyStatus == .validated)
        #expect(verifier.verifiedKeys == ["valid-key"])
    }

    @Test("Verify failure sets Invalid status")
    func verifyFailureSetsInvalid() async {
        resetSonioxDefaultsForTest()
        defer { resetSonioxDefaultsForTest() }

        let verifier = MockSettingsKeyVerifier(results: [false])
        let manager = makeSettingsManager(sonioxVerifier: verifier)
        manager.sonioxAPIKey = "bad-key"

        let result = await manager.verifySonioxKey()

        #expect(!result)
        #expect(manager.sonioxKeyStatus == .invalid)
        #expect(verifier.verifiedKeys == ["bad-key"])
    }
}

private final class MockSettingsKeyVerifier: SonioxKeyVerifying {
    var results: [Bool]
    private(set) var verifiedKeys: [String] = []

    init(results: [Bool] = [false]) {
        self.results = results
    }

    func verify(apiKey: String) async -> Bool {
        verifiedKeys.append(apiKey)
        if !results.isEmpty {
            return results.removeFirst()
        }
        return false
    }
}

@MainActor
private func makeSettingsManager(sonioxVerifier: MockSettingsKeyVerifier) -> SettingsManager {
    SettingsManager(
        sonioxKeyStore: SonioxKeyStore(verifier: sonioxVerifier),
        cartesiaKeyStore: CartesiaKeyStore(keychain: KeychainSecureStore())
    )
}

private func resetSonioxDefaultsForTest() {
    let defaults = UserDefaults.standard
    defaults.removeObject(forKey: "soniox.apiKey")
    defaults.removeObject(forKey: "soniox.apiKeyStatus")
}
