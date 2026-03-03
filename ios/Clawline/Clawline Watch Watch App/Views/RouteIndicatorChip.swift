import SwiftUI

struct RouteIndicatorChip: View {
    let transportState: WatchProviderTransportState

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
            Text(label)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .lineLimit(1)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(color.opacity(0.16))
        )
    }

    private var icon: String {
        switch transportState {
        case .direct:
            return "circle.fill"
        case .probing:
            return "circle.dotted"
        case .relay:
            return "arrow.left.arrow.right"
        case .disconnected:
            return "circle"
        }
    }

    private var label: String {
        switch transportState {
        case .direct:
            return "Direct"
        case .probing:
            return "Reconnecting..."
        case .relay:
            return "Via iPhone"
        case .disconnected:
            return "No Connection"
        }
    }

    private var color: Color {
        switch transportState {
        case .direct:
            return .green
        case .probing:
            return .yellow
        case .relay:
            return .blue
        case .disconnected:
            return .red
        }
    }
}
