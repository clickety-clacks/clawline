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
    var sharpness: Double
    var isEnabled: Bool

    init(
        effectType: ShaderEffectType,
        color1: CodableColor,
        color2: CodableColor,
        color3: CodableColor,
        intensity: Double,
        speed: Double,
        scale: Double,
        sharpness: Double,
        isEnabled: Bool
    ) {
        self.effectType = effectType
        self.color1 = color1
        self.color2 = color2
        self.color3 = color3
        self.intensity = intensity
        self.speed = speed
        self.scale = scale
        self.sharpness = sharpness
        self.isEnabled = isEnabled
    }

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
        sharpness: 2.0,
        isEnabled: true
    )

    private enum CodingKeys: String, CodingKey {
        case effectType
        case color1
        case color2
        case color3
        case intensity
        case speed
        case scale
        case sharpness
        case isEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        effectType = try container.decode(ShaderEffectType.self, forKey: .effectType)
        color1 = try container.decode(CodableColor.self, forKey: .color1)
        color2 = try container.decode(CodableColor.self, forKey: .color2)
        color3 = try container.decode(CodableColor.self, forKey: .color3)
        intensity = try container.decode(Double.self, forKey: .intensity)
        speed = try container.decode(Double.self, forKey: .speed)
        scale = try container.decode(Double.self, forKey: .scale)
        sharpness = try container.decodeIfPresent(Double.self, forKey: .sharpness) ?? 2.0
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(effectType, forKey: .effectType)
        try container.encode(color1, forKey: .color1)
        try container.encode(color2, forKey: .color2)
        try container.encode(color3, forKey: .color3)
        try container.encode(intensity, forKey: .intensity)
        try container.encode(speed, forKey: .speed)
        try container.encode(scale, forKey: .scale)
        try container.encode(sharpness, forKey: .sharpness)
        try container.encode(isEnabled, forKey: .isEnabled)
    }
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
                .float(configuration.scale),
                .float(configuration.sharpness)
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
