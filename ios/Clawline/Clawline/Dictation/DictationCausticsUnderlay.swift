//
//  DictationCausticsUnderlay.swift
//  Clawline
//
//  Created by Codex on 2/20/26.
//

import SwiftUI
import UIKit

struct DictationCausticsUnderlay: View {
    let isActive: Bool
    let amplitude: CGFloat
    let cornerRadius: CGFloat
    let reduceMotionEnabled: Bool
    let baselineSpeed: Double
    let maxSpeed: Double
    let brightness: Double
    let scale: Double
    let sharpness: Double
    let color1: Color

    private var normalizedAmplitude: Double {
        let value = max(0, min((amplitude - 0.35) / 8.65, 1))
        return Double(value)
    }

    private var effectConfig: BackgroundEffectConfiguration {
        let minSpeed: Double = reduceMotionEnabled ? 0.12 : baselineSpeed
        let effectiveMaxSpeed: Double = reduceMotionEnabled ? 0.18 : maxSpeed
        let speedLowerBound = min(minSpeed, effectiveMaxSpeed)
        let speedUpperBound = max(minSpeed, effectiveMaxSpeed)
        let clampedAmplitude = min(max(normalizedAmplitude, 0), 1)
        let smoothedAmplitude = clampedAmplitude * clampedAmplitude * (3 - (2 * clampedAmplitude))
        let rawSpeed = minSpeed + ((effectiveMaxSpeed - minSpeed) * smoothedAmplitude)
        let speed = min(max(rawSpeed, speedLowerBound), speedUpperBound)
        let intensity = brightness
        let patternScale = scale
        let lineSharpness = sharpness
        let lineColor = causticLineColor

        return BackgroundEffectConfiguration(
            effectType: .caustics,
            color1: CodableColor(color: lineColor),
            color2: CodableColor(color: lineColor),
            color3: CodableColor(color: lineColor),
            intensity: intensity,
            speed: speed,
            scale: patternScale,
            sharpness: lineSharpness,
            isEnabled: true
        )
    }

    private var causticLineColor: Color {
        let uiColor = UIColor(color1)
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        guard uiColor.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha) else {
            return Color.white
        }
        return Color(
            hue: Double(hue),
            saturation: Double(max(0.18, saturation * 0.65)),
            brightness: Double(max(0.94, brightness)),
            opacity: Double(max(0.95, alpha))
        )
    }

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color(red: 0.02, green: 0.03, blue: 0.05).opacity(0.96))
            .backgroundEffect(effectConfig)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .compositingGroup()
            .blendMode(.plusLighter)
            .opacity(isActive ? 0.92 : 0)
            .animation(.easeInOut(duration: 0.30), value: isActive)
            .allowsHitTesting(false)
    }
}
