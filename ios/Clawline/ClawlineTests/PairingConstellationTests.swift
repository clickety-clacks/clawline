//
//  PairingConstellationTests.swift
//  ClawlineTests
//

import Testing
import Foundation
import CoreGraphics
@testable import Clawline

struct PairingConstellationTests {
    @Test("Pairing constellation uses the accepted native Canvas renderer boundary")
    func pairingConstellationUsesNativeCanvasBoundary() throws {
        let sourcePath = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Clawline/Views/Pairing/PairingConstellationView.swift")
        let source = try String(contentsOf: sourcePath, encoding: .utf8)

        #expect(source.contains("Canvas(rendersAsynchronously: true)"))
        #expect(source.contains("WKWebView") == false)
        #expect(source.contains("MTKView") == false)
        #expect(source.contains("requestAnimationFrame") == false)
        #expect(source.contains("inline HTML") == false)
    }

    @Test("Pairing screen places the constellation behind pairing content and follows scene activity")
    func pairingScreenInstallsConstellationBehindContent() throws {
        let pairingSourcePath = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Clawline/Views/Pairing/PairingView.swift")
        let backgroundSourcePath = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Clawline/Views/Pairing/PairingConstellationView.swift")
        let pairingSource = try String(contentsOf: pairingSourcePath, encoding: .utf8)
        let backgroundSource = try String(contentsOf: backgroundSourcePath, encoding: .utf8)

        #expect(pairingSource.contains(".pairingConstellationBackground(isActive: scenePhase == .active)"))
        #expect(pairingSource.contains("@Environment(\\.scenePhase) private var scenePhase"))
        #expect(backgroundSource.contains(".allowsHitTesting(false)"))
        #expect(backgroundSource.contains(".accessibilityHidden(true)"))
    }

    @Test("Particle initialization is deterministic for a fixed seed")
    func deterministicParticleInitialization() {
        let first = PairingConstellationModel(count: 120, seed: 0x175)
        let second = PairingConstellationModel(count: 120, seed: 0x175)

        #expect(first == second)
        #expect(first.particles.count == 120)
        #expect(first.particles.first?.radius ?? 0 >= 1.5)
        #expect(first.particles.first?.radius ?? 0 <= 3.25)
        #expect(abs(first.particles.first?.velocity.dx ?? 0) >= 6)
        #expect(abs(first.particles.first?.velocity.dx ?? 0) <= 18)
    }

    @Test("Reduce-load and reduce-motion configuration matches pairing spec")
    func reduceMotionAndLoadConfiguration() {
        let regular = PairingConstellationConfiguration.make(
            surface: .phone,
            isCompact: false,
            lowPowerMode: false,
            reduceMotion: false,
            reduceTransparency: false
        )
        let reduced = PairingConstellationConfiguration.make(
            surface: .phone,
            isCompact: true,
            lowPowerMode: false,
            reduceMotion: true,
            reduceTransparency: true
        )
        let vision = PairingConstellationConfiguration.make(
            surface: .vision,
            isCompact: false,
            lowPowerMode: false,
            reduceMotion: false,
            reduceTransparency: false
        )

        #expect(regular.particleCount == 120)
        #expect(regular.connectionDistance == 105)
        #expect(regular.targetFrameRate == 60)
        #expect(reduced.particleCount == 80)
        #expect(reduced.reduceMotion)
        #expect(reduced.reduceTransparency)
        #expect(reduced.targetFrameRate == 30)
        #expect(vision.connectionDistance == 150)
    }
}
