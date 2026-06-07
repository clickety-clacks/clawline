//
//  MessagePresentationCopyabilityTests.swift
//  ClawlineTests
//
//  Created by Codex on 5/19/26.
//

import Foundation
import Testing
@testable import Clawline

struct MessagePresentationCopyabilityTests {
    @Test("Copyable readable text omits media-only content and uses rendered text")
    func copyableReadableTextUsesRenderedText() {
        let message = Message(
            id: "copyable-rendered-text",
            role: .assistant,
            content: "Hello *world*",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            streaming: false,
            attachments: [
                Attachment(id: "image-1", type: .image, mimeType: "image/png", data: nil, assetId: nil)
            ],
            deviceId: nil,
            sessionKey: "server:personal"
        )

        let presentation = buildPresentation(for: message)

        #expect(presentation.copyableReadableText == "Hello world")
    }

    @Test("Copyable readable text is absent for media-only content")
    func copyableReadableTextIsAbsentForMediaOnlyContent() {
        let message = Message(
            id: "copyable-media-only",
            role: .assistant,
            content: "",
            timestamp: Date(timeIntervalSince1970: 1_700_000_001),
            streaming: false,
            attachments: [
                Attachment(id: "image-2", type: .image, mimeType: "image/png", data: nil, assetId: nil)
            ],
            deviceId: nil,
            sessionKey: "server:personal"
        )

        let presentation = buildPresentation(for: message)

        #expect(presentation.copyableReadableText == nil)
    }

    private func buildPresentation(for message: Message) -> MessagePresentation {
        let metrics = ChatFlowTheme.Metrics(isCompact: false)
        var streamingState = StreamingTableParseState()
        return MessagePresentationBuilder.build(
            from: message,
            metrics: metrics,
            streamingState: &streamingState
        )
    }
}
