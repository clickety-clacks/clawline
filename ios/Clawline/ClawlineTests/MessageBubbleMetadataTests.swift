//
//  MessageBubbleMetadataTests.swift
//  ClawlineTests
//
//  Created by Codex on 5/7/26.
//

import Testing
import UIKit
@testable import Clawline

@MainActor
struct MessageBubbleMetadataTests {
    @Test("Narrow bubble hides timestamp before truncating sender")
    func narrowBubbleHidesTimestampBeforeTruncatingSender() {
        let message = Message(
            id: "metadata-narrow",
            role: .user,
            content: "Short",
            timestamp: Date(timeIntervalSince1970: 1_577_836_800),
            streaming: false,
            attachments: [],
            deviceId: nil,
            sessionKey: "server:personal"
        )
        let metrics = ChatFlowTheme.Metrics(isCompact: true)
        var streamingState = StreamingTableParseState()
        let presentation = MessagePresentationBuilder.build(
            from: message,
            metrics: metrics,
            streamingState: &streamingState
        )
        let bubble = MessageBubbleUIKitView(frame: CGRect(x: 0, y: 0, width: 120, height: 1))

        bubble.configure(
            message: message,
            presentation: presentation,
            sizeClass: .short,
            metrics: metrics,
            maxWidth: 120,
            bubbleSizingV2: nil,
            showsHeader: true,
            paddingScale: 1,
            minWidthOverride: 120,
            maxWidthOverride: 120,
            useContinuousCorners: true,
            isDark: false,
            onRequestExpand: nil,
            onRequestLayout: nil,
            onInteractiveCallback: nil
        )
        let measured = bubble.systemLayoutSizeFitting(
            CGSize(width: 120, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        bubble.frame = CGRect(origin: .zero, size: measured)
        bubble.layoutIfNeeded()

        let state = bubble.debugMetadataStateForTests()
        #expect(state.senderText == "You")
        #expect(state.senderLineBreakMode == .byClipping)
        #expect(state.senderCompressionResistance == .required)
        #expect(state.timestampCompressionResistance.rawValue < state.senderCompressionResistance.rawValue)
        #expect(state.timestampHidden)
    }

    @Test("Timestamp metadata uses readable opacity")
    func timestampMetadataUsesReadableOpacity() {
        #expect(MessageBubbleUIKitView.timestampTextAlpha(isDark: false) > 0.4)
        #expect(MessageBubbleUIKitView.timestampTextAlpha(isDark: true) > 0.4)
    }
}
