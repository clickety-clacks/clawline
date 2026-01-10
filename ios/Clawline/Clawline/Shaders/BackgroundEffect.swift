//
//  PlasmaEffect.swift
//  Clawline
//
//  Created by Codex on 1/8/26.
//

import SwiftUI

/// Configuration for the plasma effect
struct PlasmaConfiguration: Equatable, Codable {
    var color1: CodableColor
    var color2: CodableColor
    var color3: CodableColor
    var intensity: Double
    var speed: Double
    var scale: Double
    var isEnabled: Bool

    /// Off-white pastel defaults - subtle shimmer on background
    static let `default` = PlasmaConfiguration(
        color1: CodableColor(color: Color(red: 1.0, green: 0.97, blue: 0.94)),   // Warm cream
        color2: CodableColor(color: Color(red: 0.94, green: 0.97, blue: 1.0)),   // Cool ice
        color3: CodableColor(color: Color(red: 0.97, green: 0.94, blue: 1.0)),   // Soft lavender
        intensity: 0.25,
        speed: 0.2,
        scale: 2.0,
        isEnabled: true
    )
}

/// Codable wrapper for Color
struct CodableColor: Equatable, Codable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    init(color: Color) {
        let resolved = color.resolve(in: EnvironmentValues())
        self.red = Double(resolved.red)
        self.green = Double(resolved.green)
        self.blue = Double(resolved.blue)
        self.alpha = Double(resolved.opacity)
    }

    init(red: Double, green: Double, blue: Double, alpha: Double = 1.0) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    var color: Color {
        Color(red: red, green: green, blue: blue, opacity: alpha)
    }
}

/// View modifier that applies animated plasma effect
struct PlasmaEffectModifier: ViewModifier {
    let configuration: PlasmaConfiguration
    @State private var startTime: Date = .now

    func body(content: Content) -> some View {
        if configuration.isEnabled {
            TimelineView(.animation) { timeline in
                let elapsed = timeline.date.timeIntervalSince(startTime)

                content
                    .colorEffect(
                        ShaderLibrary.plasmaEffect(
                            .float(elapsed),
                            .float2(400, 400),
                            .color(configuration.color1.color),
                            .color(configuration.color2.color),
                            .color(configuration.color3.color),
                            .float(configuration.intensity),
                            .float(configuration.speed),
                            .float(configuration.scale)
                        )
                    )
            }
        } else {
            content
        }
    }
}

/// View modifier for simpler glow effect
struct PlasmaGlowModifier: ViewModifier {
    let glowColor: Color
    let intensity: Double
    let speed: Double
    let scale: Double
    let isEnabled: Bool
    @State private var startTime: Date = .now

    func body(content: Content) -> some View {
        if isEnabled {
            TimelineView(.animation) { timeline in
                let elapsed = timeline.date.timeIntervalSince(startTime)

                content
                    .colorEffect(
                        ShaderLibrary.plasmaGlow(
                            .float(elapsed),
                            .float2(400, 400),
                            .color(glowColor),
                            .float(intensity),
                            .float(speed),
                            .float(scale)
                        )
                    )
            }
        } else {
            content
        }
    }
}

// MARK: - View Extensions

extension View {
    /// Applies an animated plasma color effect
    func plasmaEffect(_ configuration: PlasmaConfiguration = .default) -> some View {
        modifier(PlasmaEffectModifier(configuration: configuration))
    }

    /// Applies a simpler animated glow effect
    func plasmaGlow(
        color: Color = .white.opacity(0.3),
        intensity: Double = 0.2,
        speed: Double = 0.5,
        scale: Double = 2.0,
        isEnabled: Bool = true
    ) -> some View {
        modifier(PlasmaGlowModifier(
            glowColor: color,
            intensity: intensity,
            speed: speed,
            scale: scale,
            isEnabled: isEnabled
        ))
    }
}
