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
        let rootView = UIView(frame: window.bounds)
        rootView.backgroundColor = .systemBackground
        rootView.isOpaque = true
        window.rootViewController = UIViewController()
        window.rootViewController?.view = rootView

        SpatialWindowTransparency.apply(to: window)

        #expect(rootView.backgroundColor == .clear)
        #expect(rootView.isOpaque == false)
    }

    @Test("Spatial transparency installer clears host ancestor chain")
    func transparencyInstallerClearsHostAncestors() {
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        let probe = UIView(frame: .zero)
        host.backgroundColor = .systemBackground
        host.isOpaque = true
        host.addSubview(probe)

        SpatialWindowTransparency.applyStarting(at: probe)

        #expect(host.backgroundColor == .clear)
        #expect(host.isOpaque == false)
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

}
