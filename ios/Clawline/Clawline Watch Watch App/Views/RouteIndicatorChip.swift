import SwiftUI

struct RouteIndicatorChip: View {
    let presentation: WatchRouteChipPresentation

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: presentation.systemImage)
                .font(.system(size: 9, weight: .semibold))
            Text(presentation.label)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .foregroundStyle(presentation.color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule()
                .fill(presentation.color.opacity(0.16))
        )
        .fixedSize(horizontal: false, vertical: true)
    }
}
