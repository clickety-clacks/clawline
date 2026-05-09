//
//  ChatPageBackgroundTests.swift
//  ClawlineTests
//
//  Created by Codex on 5/7/26.
//

import Testing
import UIKit
@testable import Clawline

@MainActor
struct ChatPageBackgroundTests {
    @Test("Light message flow host paints the design-system chat surface")
    func lightMessageFlowHostUsesDesignSystemChatSurface() {
        let color = MessageFlowCollectionViewController.chatPageBackgroundColor(isDark: false)

        #expect(Self.rgba(color) == (240, 234, 224, 255))
    }

    @Test("Dark message flow host stays transparent to preserve dark mode")
    func darkMessageFlowHostStaysTransparent() {
        let color = MessageFlowCollectionViewController.chatPageBackgroundColor(isDark: true)

        #expect(Self.rgba(color).a == 0)
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
