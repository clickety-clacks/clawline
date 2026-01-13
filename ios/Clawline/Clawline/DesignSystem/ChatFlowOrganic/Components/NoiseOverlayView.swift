//
//  NoiseOverlayView.swift
//  Clawline
//
//  Created by Codex on 1/11/26.
//

import SwiftUI

struct NoiseOverlayView: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { proxy in
            Color.white
                .opacity(colorScheme == .dark ? 0.05 : 0.12)
                .noiseEffect(
                    size: proxy.size,
                    intensity: colorScheme == .dark ? 0.04 : 0.025,
                    scale: 1.0
                )
                .blendMode(.overlay)
                .allowsHitTesting(false)
        }
    }
}

private struct NoiseEffectModifier: ViewModifier {
    let size: CGSize
    let intensity: CGFloat
    let scale: CGFloat

    func body(content: Content) -> some View {
        content.colorEffect(
            ShaderLibrary.grainNoise(
                .float(0),
                .float2(Float(size.width), Float(size.height)),
                .float(Float(intensity)),
                .float(Float(scale))
            )
        )
    }
}

private extension View {
    func noiseEffect(size: CGSize, intensity: CGFloat, scale: CGFloat) -> some View {
        modifier(NoiseEffectModifier(size: size, intensity: intensity, scale: scale))
    }
}
