import SwiftUI

struct RouteIndicatorChip: View {
    let transportState: WatchProviderTransportState

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
            Text(label)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule()
                .fill(color.opacity(0.16))
        )
        .fixedSize(horizontal: false, vertical: true)
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
