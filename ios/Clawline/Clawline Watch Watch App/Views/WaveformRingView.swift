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
    let audioLevel: Float
    let state: WatchRingVisualState

    var body: some View {
        ZStack {
            Circle()
                .stroke(baseColor.opacity(0.9), lineWidth: outerLineWidth)

            Circle()
                .stroke(Color.white.opacity(innerOpacity), lineWidth: 4)
                .scaleEffect(innerScale)
        }
        .animation(.easeOut(duration: 0.18), value: audioLevel)
        .animation(.easeOut(duration: 0.18), value: stateKey)
    }

    private var baseColor: Color {
        switch state {
        case .connectedDirect, .activeDirect:
            return .green
        case .connectedRelay, .activeRelay:
            return .blue
        case .connecting:
            return .yellow
        case .disconnected:
            return .red
        }
    }

    private var outerLineWidth: CGFloat {
        switch state {
        case .activeDirect, .activeRelay:
            return 10
        default:
            return 8
        }
    }

    private var innerOpacity: Double {
        switch state {
        case .disconnected:
            return 0.18
        case .connecting:
            return 0.24
        default:
            return 0.34
        }
    }

    private var innerScale: CGFloat {
        let levelBoost = CGFloat(min(max(audioLevel, 0), 1)) * 0.08
        switch state {
        case .activeDirect, .activeRelay:
            return 1.03 + levelBoost
        case .connecting:
            return 0.98
        default:
            return 1.0
        }
    }

    private var stateKey: Int {
        switch state {
        case .connectedDirect: return 1
        case .connectedRelay: return 2
        case .connecting: return 3
        case .disconnected: return 4
        case .activeDirect: return 5
        case .activeRelay: return 6
        }
    }
}
