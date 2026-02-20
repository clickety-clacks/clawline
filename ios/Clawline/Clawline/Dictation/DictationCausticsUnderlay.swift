//
//  DictationCausticsUnderlay.swift
//  Clawline
//
//  Created by Codex on 2/20/26.
//

import SwiftUI

struct DictationCausticsUnderlay: View {
    let isActive: Bool
    let amplitude: CGFloat
    let cornerRadius: CGFloat
    let reduceMotionEnabled: Bool
    let baselineSpeed: Double
    let maxSpeed: Double

    private var normalizedAmplitude: Double {
        let value = max(0, min((amplitude - 0.35) / 8.65, 1))
        return Double(value)
    }

    private var effectConfig: BackgroundEffectConfiguration {
        let minSpeed: Double = reduceMotionEnabled ? 0.12 : baselineSpeed
        let effectiveMaxSpeed: Double = reduceMotionEnabled ? 0.18 : maxSpeed
        let speed = minSpeed + ((effectiveMaxSpeed - minSpeed) * normalizedAmplitude)
        let intensity = 0.45 + (0.40 * normalizedAmplitude)
        let scale = 1.5 + (1.1 * normalizedAmplitude)

        return BackgroundEffectConfiguration(
            effectType: .caustics,
            color1: CodableColor(color: Color(red: 1.00, green: 0.96, blue: 0.88)),
            color2: CodableColor(color: Color(red: 0.88, green: 0.95, blue: 1.00)),
            color3: CodableColor(color: Color(red: 0.94, green: 0.91, blue: 1.00)),
            intensity: intensity,
            speed: speed,
            scale: scale,
            isEnabled: true
        )
    }

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color.white.opacity(0.30))
            .backgroundEffect(effectConfig)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .compositingGroup()
            .blendMode(.plusLighter)
            .opacity(isActive ? 0.92 : 0)
            .animation(.easeInOut(duration: 0.30), value: isActive)
            .allowsHitTesting(false)
    }
}
