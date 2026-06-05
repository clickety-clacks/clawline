//
//  ExternalWebContentPolicyTests.swift
//  ClawlineTests
//

@testable import Clawline
import Foundation
import Testing

struct ExternalWebContentPolicyTests {
    @Test("T329: LinkedIn post URL remains in the Clawline web surface")
    func linkedInPostURLRemainsEmbeddable() throws {
        let url = try #require(URL(string: "https://www.linkedin.com/posts/bryan-finster_i-keep-seeing-people-telling-on-themselves-activity-7461873611247628288-PVoZ"))

        #expect(!ExternalWebContentPolicy.shouldOpenInBrowserSurface(url))
    }

    @Test("T329: LinkedIn login URLs hand off to browser surface")
    func linkedInLoginURLsHandOffToBrowserSurface() throws {
        let loginURL = try #require(URL(string: "https://www.linkedin.com/login"))
        let uasLoginURL = try #require(URL(string: "https://www.linkedin.com/uas/login?session_redirect=https%3A%2F%2Fwww.linkedin.com%2Fposts%2Fexample"))
        let checkpointURL = try #require(URL(string: "https://www.linkedin.com/checkpoint/lg/login-submit"))
        let nonLinkedInURL = try #require(URL(string: "https://example.com/login"))

        #expect(ExternalWebContentPolicy.shouldOpenInBrowserSurface(loginURL))
        #expect(ExternalWebContentPolicy.shouldOpenInBrowserSurface(uasLoginURL))
        #expect(ExternalWebContentPolicy.shouldOpenInBrowserSurface(checkpointURL))
        #expect(!ExternalWebContentPolicy.shouldOpenInBrowserSurface(nonLinkedInURL))
    }

    @Test("T1187 generated text links use system open on Spatial browser surfaces")
    func generatedTextLinksUseSystemOpenOnSpatialBrowserSurfaces() {
        let spatialUsesSystemOpen: Bool
        switch ExternalWebContentPolicy.generatedLinkOpenRoute(isSpatial: true) {
        case .systemOpen:
            spatialUsesSystemOpen = true
        case .safariViewController:
            spatialUsesSystemOpen = false
        }

        let iPhoneUsesSafariViewController: Bool
        switch ExternalWebContentPolicy.generatedLinkOpenRoute(isSpatial: false) {
        case .systemOpen:
            iPhoneUsesSafariViewController = false
        case .safariViewController:
            iPhoneUsesSafariViewController = true
        }

        #expect(spatialUsesSystemOpen)
        #expect(iPhoneUsesSafariViewController)
    }
}
