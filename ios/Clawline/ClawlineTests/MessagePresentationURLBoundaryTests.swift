//
//  MessagePresentationURLBoundaryTests.swift
//  ClawlineTests
//

import Testing
import Foundation
@testable import Clawline

struct MessagePresentationURLBoundaryTests {
    @Test("Wrapped mark delimiters do not leak into link preview hrefs")
    func wrappedMarkDelimitersDoNotLeakIntoLinkPreviewHrefs() {
        let presentation = buildPresentation(content: "==https://example.com==")

        #expect(presentation.detectedURLs.map(\.absoluteString) == ["https://example.com"])
        #expect(presentation.parts.contains(where: { part in
            if case .linkPreview(let url) = part {
                return url.absoluteString == "https://example.com"
            }
            return false
        }))
    }

    @Test("Wrapped mark delimiters preserve legitimate query values containing double equals")
    func wrappedMarkDelimitersPreserveLegitimateQueryValues() {
        let content = "==https://example.com/path?token=YWJjZA===="
        let expectedURL = "https://example.com/path?token=YWJjZA=="
        let presentation = buildPresentation(content: content)

        #expect(presentation.detectedURLs.map(\.absoluteString) == [expectedURL])
        #expect(presentation.parts.contains(where: { part in
            if case .linkPreview(let url) = part {
                return url.absoluteString == expectedURL
            }
            return false
        }))
    }

    private func buildPresentation(content: String) -> MessagePresentation {
        let message = Message(
            id: "m_url_boundary",
            role: .assistant,
            content: content,
            timestamp: Date(),
            streaming: false,
            attachments: [],
            deviceId: nil,
            sessionKey: "agent:main:clawline:user:main"
        )
        var state = StreamingTableParseState()
        return MessagePresentationBuilder.build(
            from: message,
            metrics: ChatFlowTheme.Metrics(isCompact: true),
            streamingState: &state
        )
    }
}
