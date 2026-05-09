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
        #expect(Self.rgba(colors[0]) == (220, 241, 210, 255))
    }

    @Test("Dark user prompt bubble fill stays unchanged")
    func darkUserPromptBubbleFillStaysUnchanged() {
        let colors = ChatFlowUIKitTheme.palette(isDark: true).bubbleSelfGradient

        #expect(Self.rgba(colors[0]) == (45, 59, 42, 255))
        #expect(Self.rgba(colors[1]) == (36, 51, 34, 255))
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
