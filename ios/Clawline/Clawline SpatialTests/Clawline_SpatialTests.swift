//
//  Clawline_SpatialTests.swift
//  Clawline SpatialTests
//
//  Created by Mike Manzano on 1/28/26.
//

import Testing
import UIKit
@testable import Clawline_Spatial

@MainActor
struct Clawline_SpatialTests {

    @Test("Spatial transparency installer clears root view")
    func transparencyInstallerClearsRootView() {
        let window = makeWindow()
        let rootView = TestUIHostingView(frame: window.bounds)
        rootView.backgroundColor = .systemBackground
        rootView.isOpaque = true
        window.rootViewController = UIViewController()
        window.rootViewController?.view = rootView

        SpatialWindowTransparency.apply(to: window)

        #expect(rootView.backgroundColor == .clear)
        #expect(rootView.isOpaque == false)
    }

    @Test("Spatial transparency installer clears hosting ancestors only")
    func transparencyInstallerClearsHostingAncestorsOnly() {
        let host = TestUIHostingView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        let ordinaryAncestor = UIView(frame: host.bounds)
        let probe = UIView(frame: .zero)
        host.backgroundColor = .systemBackground
        host.isOpaque = true
        ordinaryAncestor.backgroundColor = .secondarySystemBackground
        ordinaryAncestor.isOpaque = true
        host.addSubview(ordinaryAncestor)
        ordinaryAncestor.addSubview(probe)

        SpatialWindowTransparency.applyStarting(at: probe)

        #expect(host.backgroundColor == .clear)
        #expect(host.isOpaque == false)
        #expect(ordinaryAncestor.backgroundColor == .secondarySystemBackground)
        #expect(ordinaryAncestor.isOpaque == true)
    }

    @Test("Spatial recursive scrub is scoped to window and hosting views")
    func recursiveScrubScope() {
        let window = makeWindow()
        let ordinarySubview = UIView(frame: window.bounds)
        ordinarySubview.backgroundColor = .systemBackground
        ordinarySubview.isOpaque = true
        window.addSubview(ordinarySubview)

        SpatialWindowTransparency.setHostingBackgroundsClear(in: window)

        #expect(window.backgroundColor == .clear)
        #expect(window.isOpaque == false)
        #expect(ordinarySubview.backgroundColor == .systemBackground)
        #expect(ordinarySubview.isOpaque == true)
    }

    @Test("Spatial transparent message flow installs gaze scroll hit surface")
    func transparentMessageFlowInstallsGazeScrollHitSurface() {
        let controller = MessageFlowCollectionViewController()
        controller.prepareInitialAppearance(isDark: false, allowsTransparentWindowBackground: true)

        controller.loadViewIfNeeded()

        let collectionView = controller.view.subviews.compactMap { $0 as? UICollectionView }.first
        let hitSurface = collectionView?.backgroundView as? SpatialGazeScrollHitSurfaceView
        #expect(hitSurface != nil)
        #expect(hitSurface?.isUserInteractionEnabled == true)
        #expect(hitSurface?.isOpaque == false)
        #expect(alpha(hitSurface?.backgroundColor ?? .clear) > 0)
        #expect(alpha(hitSurface?.backgroundColor ?? .clear) < (1.0 / 255.0))
        #expect(rgba(hitSurface?.backgroundColor ?? .clear).a == 0)
    }

    @Test("Spatial normal message flow does not install gaze scroll hit surface")
    func normalMessageFlowDoesNotInstallGazeScrollHitSurface() {
        let controller = MessageFlowCollectionViewController()
        controller.prepareInitialAppearance(isDark: false, allowsTransparentWindowBackground: false)

        controller.loadViewIfNeeded()

        let collectionView = controller.view.subviews.compactMap { $0 as? UICollectionView }.first
        #expect(collectionView?.backgroundView == nil)
    }

    private func makeWindow() -> UIWindow {
        let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first
        #expect(scene != nil)
        guard let scene else {
            fatalError("Expected a test host window scene")
        }
        return UIWindow(windowScene: scene)
    }

    private func rgba(_ color: UIColor) -> (r: Int, g: Int, b: Int, a: Int) {
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

    private func alpha(_ color: UIColor) -> CGFloat {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return alpha
    }

}

private final class TestUIHostingView: UIView {}
