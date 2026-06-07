import SwiftUI

struct ClawlineWindowCornerIndicators: View {
    private let edgeInset: CGFloat = 10

    var body: some View {
        HStack {
            ClawlineWindowCornerIndicator(edge: .leading)
                .offset(x: -edgeInset, y: edgeInset)
            Spacer(minLength: 0)
            ClawlineWindowCornerIndicator(edge: .trailing)
                .offset(x: edgeInset, y: edgeInset)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, edgeInset)
        .padding(.bottom, edgeInset)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct ClawlineWindowCornerIndicator: View {
    enum Edge {
        case leading
        case trailing
    }

    let edge: Edge

    var body: some View {
        Canvas { context, size in
            var path = Path()
            let radius = min(cornerRadius, size.width - lineWidth, size.height - lineWidth)
            let strokeInset = lineWidth / 2

            switch edge {
            case .leading:
                path.addArc(
                    center: CGPoint(
                        x: strokeInset + radius,
                        y: size.height - strokeInset - radius
                    ),
                    radius: radius,
                    startAngle: .degrees(180),
                    endAngle: .degrees(90),
                    clockwise: true
                )
            case .trailing:
                path.addArc(
                    center: CGPoint(
                        x: size.width - strokeInset - radius,
                        y: size.height - strokeInset - radius
                    ),
                    radius: radius,
                    startAngle: .degrees(0),
                    endAngle: .degrees(90),
                    clockwise: false
                )
            }

            context.stroke(
                path,
                with: .color(.white.opacity(0.24)),
                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
            )
        }
        .frame(width: markerSize, height: markerSize)
    }

    private var markerSize: CGFloat { 34 }
    private var cornerRadius: CGFloat { 30 }
    private var lineWidth: CGFloat { 3 }
}
