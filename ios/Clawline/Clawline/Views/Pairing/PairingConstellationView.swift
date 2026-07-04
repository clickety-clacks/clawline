//
//  PairingConstellationView.swift
//  Clawline
//
//  Created by Codex on 7/4/26.
//

import SwiftUI
#if os(iOS)
import UIKit
#endif

struct PairingConstellationConfiguration: Equatable {
    enum Surface: Equatable {
        case phone
        case pad
        case vision
    }

    let particleCount: Int
    let connectionDistance: CGFloat
    let reduceMotion: Bool
    let reduceTransparency: Bool
    let targetFrameRate: Int

    static let regularParticleCount = 120
    static let reducedParticleCount = 80
    static let palette: [Color] = [
        Color(red: 0x2f / 255, green: 0x8d / 255, blue: 0xff / 255),
        Color(red: 0x19 / 255, green: 0xd3 / 255, blue: 0xff / 255),
        Color(red: 0x16 / 255, green: 0xd9 / 255, blue: 0xd2 / 255),
        Color(red: 0x43 / 255, green: 0xf0 / 255, blue: 0xb4 / 255)
    ]

    static func make(
        surface: Surface,
        isCompact: Bool,
        lowPowerMode: Bool,
        reduceMotion: Bool,
        reduceTransparency: Bool,
        sustainedFrameMisses: Bool = false
    ) -> PairingConstellationConfiguration {
        let shouldReduceLoad = isCompact || lowPowerMode || sustainedFrameMisses
        let connectionDistance: CGFloat = switch surface {
        case .phone:
            105
        case .pad:
            130
        case .vision:
            150
        }

        return PairingConstellationConfiguration(
            particleCount: shouldReduceLoad ? reducedParticleCount : regularParticleCount,
            connectionDistance: connectionDistance,
            reduceMotion: reduceMotion,
            reduceTransparency: reduceTransparency,
            targetFrameRate: shouldReduceLoad ? 30 : 60
        )
    }
}

struct PairingConstellationParticle: Equatable {
    let unitPosition: CGPoint
    let velocity: CGVector
    let wanderPhase: Double
    let wanderAmplitude: CGFloat
    let radius: CGFloat
    let paletteIndex: Int
}

struct PairingConstellationModel: Equatable {
    let particles: [PairingConstellationParticle]

    init(count: Int, seed: UInt64 = 0x175C0A57E11A7105) {
        var generator = PairingConstellationGenerator(seed: seed)
        particles = (0..<count).map { index in
            PairingConstellationParticle(
                unitPosition: CGPoint(
                    x: generator.nextCGFloat(in: 0...1),
                    y: generator.nextCGFloat(in: 0...1)
                ),
                velocity: CGVector(
                    dx: generator.nextSignedSpeed(),
                    dy: generator.nextSignedSpeed()
                ),
                wanderPhase: generator.nextDouble(in: 0...(Double.pi * 2)),
                wanderAmplitude: generator.nextCGFloat(in: 4...14),
                radius: generator.nextCGFloat(in: 1.5...3.25),
                paletteIndex: index % PairingConstellationConfiguration.palette.count
            )
        }
    }
}

private struct PairingConstellationView: View {
    let isActive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        GeometryReader { geometry in
            let configuration = PairingConstellationConfiguration.make(
                surface: Self.surface,
                isCompact: geometry.size.width < 430,
                lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
                reduceMotion: reduceMotion,
                reduceTransparency: reduceTransparency
            )
            let model = PairingConstellationModel(count: configuration.particleCount)

            TimelineView(.animation(paused: !isActive)) { timeline in
                Canvas(rendersAsynchronously: true) { context, size in
                    let elapsed = isActive ? timeline.date.timeIntervalSinceReferenceDate : 0
                    drawConstellation(
                        context: &context,
                        size: size,
                        elapsed: elapsed,
                        model: model,
                        configuration: configuration
                    )
                }
            }
            .background(Color.black)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private static var surface: PairingConstellationConfiguration.Surface {
#if os(visionOS)
        .vision
#elseif os(iOS)
        UIDevice.current.userInterfaceIdiom == .pad ? .pad : .phone
#else
        .pad
#endif
    }

    private func drawConstellation(
        context: inout GraphicsContext,
        size: CGSize,
        elapsed: TimeInterval,
        model: PairingConstellationModel,
        configuration: PairingConstellationConfiguration
    ) {
        guard size.width > 0, size.height > 0 else { return }

        let points = model.particles.map {
            particlePosition(
                for: $0,
                size: size,
                elapsed: elapsed,
                reduceMotion: configuration.reduceMotion
            )
        }
        let shimmer = configuration.reduceMotion && !configuration.reduceTransparency
            ? 0.82 + 0.18 * sin((elapsed / 6) * Double.pi * 2)
            : 1

        for leftIndex in points.indices {
            for rightIndex in points.index(after: leftIndex)..<points.endIndex {
                let distance = points[leftIndex].distance(to: points[rightIndex])
                guard distance <= configuration.connectionDistance else { continue }

                let progress = max(0, min(1, distance / configuration.connectionDistance))
                let alpha = (0.22 * (1 - progress)) * shimmer
                var path = Path()
                path.move(to: points[leftIndex])
                path.addLine(to: points[rightIndex])
                context.stroke(
                    path,
                    with: .color(Color(red: 0x16 / 255, green: 0xd9 / 255, blue: 0xd2 / 255).opacity(alpha)),
                    lineWidth: min(1.5, 1.5 * (1 - progress) + 0.25)
                )
            }
        }

        for (index, particle) in model.particles.enumerated() {
            let point = points[index]
            let radius = particle.radius
            let rect = CGRect(
                x: point.x - radius,
                y: point.y - radius,
                width: radius * 2,
                height: radius * 2
            )
            let color = PairingConstellationConfiguration.palette[particle.paletteIndex]
            context.fill(Path(ellipseIn: rect), with: .color(color.opacity(0.72 * shimmer)))
        }
    }

    private func particlePosition(
        for particle: PairingConstellationParticle,
        size: CGSize,
        elapsed: TimeInterval,
        reduceMotion: Bool
    ) -> CGPoint {
        let base = CGPoint(
            x: particle.unitPosition.x * size.width,
            y: particle.unitPosition.y * size.height
        )
        guard !reduceMotion else { return base }

        let wander = sin(elapsed * 0.22 + particle.wanderPhase) * particle.wanderAmplitude
        let x = wrap(base.x + particle.velocity.dx * elapsed + wander, limit: size.width)
        let y = wrap(base.y + particle.velocity.dy * elapsed + wander * 0.65, limit: size.height)
        return CGPoint(x: x, y: y)
    }

    private func wrap(_ value: CGFloat, limit: CGFloat) -> CGFloat {
        guard limit > 0 else { return 0 }
        let wrapped = value.truncatingRemainder(dividingBy: limit)
        return wrapped >= 0 ? wrapped : wrapped + limit
    }
}

private struct PairingConstellationGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func nextDouble(in range: ClosedRange<Double>) -> Double {
        let value = Double(next() >> 11) / Double(1 << 53)
        return range.lowerBound + (range.upperBound - range.lowerBound) * value
    }

    mutating func nextCGFloat(in range: ClosedRange<CGFloat>) -> CGFloat {
        CGFloat(nextDouble(in: Double(range.lowerBound)...Double(range.upperBound)))
    }

    mutating func nextSignedSpeed() -> CGFloat {
        let magnitude = nextCGFloat(in: 6...18)
        return next().isMultiple(of: 2) ? magnitude : -magnitude
    }

    private mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

private extension CGPoint {
    func distance(to other: CGPoint) -> CGFloat {
        hypot(x - other.x, y - other.y)
    }
}

extension View {
    func pairingConstellationBackground(isActive: Bool) -> some View {
        ZStack {
            PairingConstellationView(isActive: isActive)
            self
        }
    }
}
