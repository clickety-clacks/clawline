import SwiftUI

enum WatchRingVisualState {
    case connectedDirect
    case connectedRelay
    case connecting
    case disconnected
    case activeDirect
    case activeRelay
}

struct WaveformRingView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let audioLevel: Float
    let state: WatchRingVisualState

    var body: some View {
        TimelineView(.animation(paused: !isAnimated)) { timeline in
            let now = timeline.date.timeIntervalSinceReferenceDate
            let base = reduceMotion ? 0.0 : now
            let displacement = displacementForLevel(audioLevel)
            let speed = speedForLevel(audioLevel)

            ZStack {
                outerRing(base: base)
                innerRing(base: base, displacement: displacement, speed: speed)
            }
        }
    }

    private var isAnimated: Bool {
        switch state {
        case .connectedDirect, .connectedRelay, .connecting, .activeDirect, .activeRelay:
            return true
        case .disconnected:
            return false
        }
    }

    @ViewBuilder
    private func outerRing(base: Double) -> some View {
        switch state {
        case .connectedDirect, .activeDirect:
            Circle()
                .stroke(
                    AngularGradient(
                        colors: [.cyan, .mint, .green, .yellow, .orange, .pink, .cyan],
                        center: .center,
                        angle: .degrees(base * 24)
                    ),
                    lineWidth: 8
                )
                .opacity(0.95)
        case .connectedRelay, .activeRelay:
            Circle()
                .stroke(
                    AngularGradient(
                        colors: [.blue, .cyan, .teal, .mint, .indigo, .blue],
                        center: .center,
                        angle: .degrees(base * 18)
                    ),
                    lineWidth: 8
                )
                .opacity(0.95)
        case .connecting:
            Circle()
                .stroke(Color.secondary.opacity(0.75), lineWidth: 8)
                .scaleEffect(reduceMotion ? 1.0 : 1.0 + CGFloat((sin(base * 3.0) + 1.0) * 0.03))
        case .disconnected:
            Circle()
                .stroke(Color.secondary.opacity(0.45), lineWidth: 8)
        }
    }

    @ViewBuilder
    private func innerRing(base: Double, displacement: CGFloat, speed: Double) -> some View {
        switch state {
        case .connectedDirect, .connectedRelay, .activeDirect, .activeRelay:
            if reduceMotion {
                Circle()
                    .stroke(Color.white.opacity(0.3), lineWidth: 4)
                    .scaleEffect(1.0 + displacement * 0.08)
            } else {
                Circle()
                    .trim(from: 0.1, to: 0.9)
                    .stroke(Color.white.opacity(0.35), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(base * speed * 40))
                    .scaleEffect(1.0 + displacement * 0.1)
            }
        case .connecting:
            Circle()
                .stroke(Color.white.opacity(0.2), lineWidth: 4)
                .scaleEffect(reduceMotion ? 1.0 : 1.0 + CGFloat((sin(base * 3.0) + 1.0) * 0.02))
        case .disconnected:
            Circle()
                .stroke(Color.white.opacity(0.12), lineWidth: 4)
        }
    }

    private func displacementForLevel(_ level: Float) -> CGFloat {
        let clamped = max(0, min(12, Double(level * 20)))
        return CGFloat(tanh(clamped / 4.0))
    }

    private func speedForLevel(_ level: Float) -> Double {
        let value = max(0, Double(level * 18))
        return 0.4 + pow(value + 1.0, 0.6) * 0.35
    }
}
