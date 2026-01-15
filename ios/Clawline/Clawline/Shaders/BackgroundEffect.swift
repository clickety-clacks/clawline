//
//  BackgroundEffect.swift
//  Clawline
//
//  Created by Codex on 1/8/26.
//

import SwiftUI

/// Effect type selection
enum ShaderEffectType: String, Codable, CaseIterable {
    case plasma = "Plasma"
    case caustics = "Caustics"
}

/// Configuration for background shader effects
struct BackgroundEffectConfiguration: Equatable, Codable {
    var effectType: ShaderEffectType
    var color1: CodableColor
    var color2: CodableColor
    var color3: CodableColor
    var intensity: Double
    var speed: Double
    var scale: Double
    var isEnabled: Bool

    /// Off-white pastel defaults - subtle shimmer on background
    /// For caustics: brighter warm white simulates sunlight through water
    /// For plasma: off-white pastels create subtle color flow
    static let `default` = BackgroundEffectConfiguration(
        effectType: .caustics,
        color1: CodableColor(color: Color(red: 1.0, green: 0.95, blue: 0.85)),   // Warm golden white (sunlight)
        color2: CodableColor(color: Color(red: 0.94, green: 0.97, blue: 1.0)),   // Cool ice
        color3: CodableColor(color: Color(red: 0.97, green: 0.94, blue: 1.0)),   // Soft lavender
        intensity: 0.35,
        speed: 0.25,
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

/// View modifier that applies animated shader effect (plasma or caustics)
struct BackgroundEffectModifier: ViewModifier {
    let configuration: BackgroundEffectConfiguration
    @State private var startTime: Date = .now

    func body(content: Content) -> some View {
        if configuration.isEnabled {
            TimelineView(.animation) { timeline in
                let elapsed = timeline.date.timeIntervalSince(startTime)

                content
                    .colorEffect(shaderForEffect(elapsed: elapsed))
            }
        } else {
            content
        }
    }

    private func shaderForEffect(elapsed: TimeInterval) -> Shader {
        switch configuration.effectType {
        case .plasma:
            return ShaderLibrary.plasmaEffect(
                .float(elapsed),
                .float2(400, 400),
                .color(configuration.color1.color),
                .color(configuration.color2.color),
                .color(configuration.color3.color),
                .float(configuration.intensity),
                .float(configuration.speed),
                .float(configuration.scale)
            )
        case .caustics:
            return ShaderLibrary.causticsEffect(
                .float(elapsed),
                .float2(400, 400),
                .color(configuration.color1.color),
                .float(configuration.intensity),
                .float(configuration.speed),
                .float(configuration.scale)
            )
        }
    }
}

// MARK: - View Extensions

extension View {
    /// Applies an animated background shader effect (plasma or caustics)
    func backgroundEffect(_ configuration: BackgroundEffectConfiguration = .default) -> some View {
        modifier(BackgroundEffectModifier(configuration: configuration))
    }
}
