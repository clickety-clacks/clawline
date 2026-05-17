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

    @Test("Transparent window hosts keep light message flow clear")
    func transparentWindowHostKeepsLightMessageFlowClear() {
        let color = MessageFlowCollectionViewController.chatPageBackgroundColor(
            isDark: false,
            allowsTransparentWindowBackground: true
        )

        #expect(Self.rgba(color).a == 0)
    }

    @Test("Transparent window hosts seed clear backgrounds before first update")
    func transparentWindowHostSeedsClearBackgroundsBeforeFirstUpdate() {
        let controller = MessageFlowCollectionViewController()
        controller.prepareInitialAppearance(isDark: false, allowsTransparentWindowBackground: true)

        controller.loadViewIfNeeded()

        let collectionView = controller.view.subviews.compactMap { $0 as? UICollectionView }.first
        #expect(Self.rgba(controller.view.backgroundColor ?? .black).a == 0)
        #expect(controller.view.isOpaque == false)
        #expect(collectionView != nil)
        #expect(Self.rgba(collectionView?.backgroundColor ?? .black).a == 0)
        #expect(collectionView?.isOpaque == false)
    }

    @Test("Normal light hosts keep design background before first update")
    func normalLightHostSeedsDesignBackgroundBeforeFirstUpdate() {
        let controller = MessageFlowCollectionViewController()
        controller.prepareInitialAppearance(isDark: false, allowsTransparentWindowBackground: false)

        controller.loadViewIfNeeded()

        let collectionView = controller.view.subviews.compactMap { $0 as? UICollectionView }.first
        #expect(Self.rgba(controller.view.backgroundColor ?? .clear) == (240, 234, 224, 255))
        #expect(controller.view.isOpaque)
        #expect(collectionView != nil)
        #expect(Self.rgba(collectionView?.backgroundColor ?? .clear) == (240, 234, 224, 255))
        #expect(collectionView?.isOpaque == true)
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
