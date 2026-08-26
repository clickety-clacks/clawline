//
//  MessageBubbleShadowTests.swift
//  ClawlineTests
//
//  Created by Codex on 5/7/26.
//

import Testing
import UIKit
@testable import Clawline

@MainActor
struct MessageBubbleShadowTests {
    @Test("Bubble shadows use the pre-canvas per-bubble opacity")
    func bubbleShadowsUsePreCanvasOpacity() {
        #expect(MessageBubbleShadowStyle.opacity(isDark: false) == 0.24)
        #expect(MessageBubbleShadowStyle.opacity(isDark: true) == 0.25)
        #expect(MessageBubbleShadowStyle.radius == 12)
        #expect(MessageBubbleShadowStyle.offset == CGSize(width: 0, height: 5))
    }

    @Test("Light user prompt bubble fill is flat")
    func lightUserPromptBubbleFillIsFlat() {
        let colors = ChatFlowUIKitTheme.palette(isDark: false).bubbleSelfGradient

        #expect(colors.count == 2)
        #expect(colors.first == colors.last)
        #expect(Self.rgba(colors[0]) == (213, 237, 201, 255))
    }

    @Test("Dark user prompt bubble fill stays unchanged")
    func darkUserPromptBubbleFillStaysUnchanged() {
        let colors = ChatFlowUIKitTheme.palette(isDark: true).bubbleSelfGradient

        #expect(Self.rgba(colors[0]) == (41, 55, 38, 255))
        #expect(Self.rgba(colors[1]) == (32, 46, 30, 255))
    }

    @Test("Canceled prompt bubble uses gray ghost fill")
    func canceledPromptBubbleUsesGrayGhostFill() {
        let lightColors = ChatFlowUIKitTheme.canceledBubbleGradient(isDark: false)
        let darkColors = ChatFlowUIKitTheme.canceledBubbleGradient(isDark: true)

        #expect(Self.rgba(lightColors[0]) == (227, 229, 230, 255))
        #expect(Self.rgba(lightColors[1]) == (217, 220, 221, 255))
        #expect(Self.rgba(darkColors[0]) == (38, 39, 41, 255))
        #expect(Self.rgba(darkColors[1]) == (29, 30, 31, 255))
    }

    @Test("Legacy messages decode as normal delivery state")
    func legacyMessagesDecodeAsNormalDeliveryState() throws {
        let json = """
        {
          "id": "s_legacy",
          "role": "user",
          "content": "legacy",
          "timestamp": 1700000000,
          "streaming": false,
          "attachments": [],
          "deviceId": "device",
          "sessionKey": "agent:main:clawline:user:s_personal"
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let message = try decoder.decode(Message.self, from: Data(json.utf8))

        #expect(message.deliveryState == .normal)
    }

    private static func rgba(_ color: UIColor) -> (r: Int, g: Int, b: Int, a: Int) {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return (
            Int((red * 255).rounded()),
            Int((green * 255).rounded()),
            Int((blue * 255).rounded()),
            Int((alpha * 255).rounded())
        )
    }
}
