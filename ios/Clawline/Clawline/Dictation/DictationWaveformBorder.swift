//
//  DictationWaveformBorder.swift
//  Clawline
//
//  Created by Codex on 2/13/26.
//

import SwiftUI

struct DictationWaveformBorder: View {
    let isActive: Bool
    let amplitude: CGFloat
    let cornerRadius: CGFloat
    let reduceMotionEnabled: Bool

    private let strokeColor = Color.accentColor

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.10)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            if reduceMotionEnabled {
                let alpha = 0.825 + 0.175 * sin(t * .pi * 2)
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(strokeColor.opacity(isActive ? alpha : 0), lineWidth: 1.5)
            } else {
                GeometryReader { geometry in
                    let phase = CGFloat(t * .pi * 2 * 0.5)
                    let path = DictationWavePath.path(
                        in: geometry.frame(in: .local),
                        cornerRadius: cornerRadius,
                        amplitude: isActive ? amplitude : 0,
                        phase: phase
                    )
                    path
                        .stroke(strokeColor.opacity(isActive ? 0.95 : 0), lineWidth: 1.5)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

private enum DictationWavePath {
    static func path(in rect: CGRect, cornerRadius: CGFloat, amplitude: CGFloat, phase: CGFloat) -> Path {
        let clampedAmplitude = max(0, amplitude)
        let inset = clampedAmplitude + 2
        let insetRect = rect.insetBy(dx: inset, dy: inset)
        guard insetRect.width > 8, insetRect.height > 8 else {
            return RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).path(in: rect)
        }

        let radius = max(0, min(cornerRadius, min(insetRect.width, insetRect.height) / 2))
        let topLength = max(0, insetRect.width - 2 * radius)
        let sideLength = max(0, insetRect.height - 2 * radius)
        let quarterArc = (.pi / 2) * radius
        let perimeter = 2 * (topLength + sideLength) + 4 * quarterArc

        guard perimeter > 0 else {
            return RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: insetRect)
        }

        let wavelength: CGFloat = 36
        let waveNumber = 2 * CGFloat.pi / wavelength
        let step: CGFloat = 4

        var path = Path()
        var distance: CGFloat = 0
        var isFirst = true

        while distance <= perimeter {
            let location = pointAndNormal(distance: distance, in: insetRect, radius: radius, topLength: topLength, sideLength: sideLength, quarterArc: quarterArc)
            let offset = sin(waveNumber * distance + phase) * clampedAmplitude
            let point = CGPoint(
                x: location.point.x + location.normal.dx * offset,
                y: location.point.y + location.normal.dy * offset
            )

            if isFirst {
                path.move(to: point)
                isFirst = false
            } else {
                path.addLine(to: point)
            }

            distance += step
        }

        if let start = path.currentPoint {
            path.addLine(to: start)
        }
        path.closeSubpath()
        return path
    }

    private static func pointAndNormal(
        distance: CGFloat,
        in rect: CGRect,
        radius: CGFloat,
        topLength: CGFloat,
        sideLength: CGFloat,
        quarterArc: CGFloat
    ) -> (point: CGPoint, normal: CGVector) {
        var d = distance

        if d <= topLength {
            return (
                CGPoint(x: rect.minX + radius + d, y: rect.minY),
                CGVector(dx: 0, dy: -1)
            )
        }
        d -= topLength

        if d <= quarterArc, radius > 0 {
            let theta = -CGFloat.pi / 2 + (d / quarterArc) * (CGFloat.pi / 2)
            let center = CGPoint(x: rect.maxX - radius, y: rect.minY + radius)
            return (
                CGPoint(x: center.x + cos(theta) * radius, y: center.y + sin(theta) * radius),
                CGVector(dx: cos(theta), dy: sin(theta))
            )
        }
        d -= quarterArc

        if d <= sideLength {
            return (
                CGPoint(x: rect.maxX, y: rect.minY + radius + d),
                CGVector(dx: 1, dy: 0)
            )
        }
        d -= sideLength

        if d <= quarterArc, radius > 0 {
            let theta = (d / quarterArc) * (CGFloat.pi / 2)
            let center = CGPoint(x: rect.maxX - radius, y: rect.maxY - radius)
            return (
                CGPoint(x: center.x + cos(theta) * radius, y: center.y + sin(theta) * radius),
                CGVector(dx: cos(theta), dy: sin(theta))
            )
        }
        d -= quarterArc

        if d <= topLength {
            return (
                CGPoint(x: rect.maxX - radius - d, y: rect.maxY),
                CGVector(dx: 0, dy: 1)
            )
        }
        d -= topLength

        if d <= quarterArc, radius > 0 {
            let theta = CGFloat.pi / 2 + (d / quarterArc) * (CGFloat.pi / 2)
            let center = CGPoint(x: rect.minX + radius, y: rect.maxY - radius)
            return (
                CGPoint(x: center.x + cos(theta) * radius, y: center.y + sin(theta) * radius),
                CGVector(dx: cos(theta), dy: sin(theta))
            )
        }
        d -= quarterArc

        if d <= sideLength {
            return (
                CGPoint(x: rect.minX, y: rect.maxY - radius - d),
                CGVector(dx: -1, dy: 0)
            )
        }
        d -= sideLength

        if quarterArc > 0, radius > 0 {
            let theta = CGFloat.pi + (d / quarterArc) * (CGFloat.pi / 2)
            let center = CGPoint(x: rect.minX + radius, y: rect.minY + radius)
            return (
                CGPoint(x: center.x + cos(theta) * radius, y: center.y + sin(theta) * radius),
                CGVector(dx: cos(theta), dy: sin(theta))
            )
        }

        return (
            CGPoint(x: rect.minX + radius, y: rect.minY),
            CGVector(dx: 0, dy: -1)
        )
    }
}
