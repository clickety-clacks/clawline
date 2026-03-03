import SwiftUI

struct WaveformRingView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let audioLevel: Float
    let isActive: Bool

    @State private var phase: CGFloat = 0

    var body: some View {
        TimelineView(.animation) { timeline in
            let now = timeline.date.timeIntervalSinceReferenceDate
            let base = reduceMotion ? 0.0 : now
            let displacement = displacementForLevel(audioLevel)
            let speed = speedForLevel(audioLevel)

            ZStack {
                Circle()
                    .stroke(
                        AngularGradient(
                            colors: [.cyan, .mint, .green, .yellow, .orange, .pink, .cyan],
                            center: .center,
                            angle: .degrees(base * 24)
                        ),
                        lineWidth: 8
                    )
                    .opacity(isActive ? 0.95 : 0.55)

                if reduceMotion {
                    Circle()
                        .stroke(Color.white.opacity(isActive ? 0.35 : 0.15), lineWidth: 4)
                        .scaleEffect(isActive ? 1.0 + displacement * 0.08 : 1.0)
                } else {
                    Circle()
                        .trim(from: 0.1, to: 0.9)
                        .stroke(Color.white.opacity(0.35), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(base * speed * 40))
                        .scaleEffect(1.0 + displacement * 0.1)
                }
            }
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
