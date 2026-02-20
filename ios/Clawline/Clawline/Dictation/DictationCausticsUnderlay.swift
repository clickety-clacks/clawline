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

    private var normalizedAmplitude: Double {
        let value = max(0, min((amplitude - 0.35) / 8.65, 1))
        return Double(value)
    }

    private var effectConfig: BackgroundEffectConfiguration {
        let minSpeed: Double = reduceMotionEnabled ? 0.04 : 0.08
        let maxSpeed: Double = reduceMotionEnabled ? 0.12 : 0.42
        let speed = minSpeed + ((maxSpeed - minSpeed) * normalizedAmplitude)
        let intensity = 0.20 + (0.35 * normalizedAmplitude)
        let scale = 1.7 + (0.8 * normalizedAmplitude)

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
            .fill(Color.white.opacity(0.14))
            .backgroundEffect(effectConfig)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .opacity(isActive ? 1 : 0)
            .animation(.easeInOut(duration: 0.25), value: isActive)
            .allowsHitTesting(false)
    }
}
