//
//  MarkerDividerCell.swift
//  Clawline
//
//  A session-info firing is the only structurally reliable boundary signal
//  available on the wire today. The collection view places this divider at
//  that boundary and supplies the minimal honest presentation below. Rich
//  kind/from/to labels stay deferred until a typed marker payload exists.
//
//  Cycle-3 Goal A, step 3b. The divider doubles as the segment-anchor's
//  entry point: tapping it toggles show-only-since-this-boundary. No
//  separate chrome is added for this -- the divider is already the one
//  place in the UI that names the boundary, so it is the natural (and
//  minimal) place to act on it.
//

import UIKit

/// Render-ready divider content. Keeping wire interpretation outside the cell
/// lets a future typed marker payload map into this seam without changing its
/// date-divider layout.
struct MarkerDividerContent: Equatable {
    let label: String
    let accessibilityLabel: String

    static let sessionBoundary = MarkerDividerContent(
        label: "SESSION BOUNDARY",
        accessibilityLabel: "Session boundary"
    )
}

final class MarkerDividerCell: UICollectionViewCell {
    static let reuseIdentifier = "MarkerDividerCell"
    static let itemIdPrefix = "__marker_divider__|"
    static let verticalPadding: CGFloat = 8

    private let leadingRule = UIView()
    private let trailingRule = UIView()
    private let flagView = MarkerFlagView()
    private let label = UILabel()
    private let stack = UIStackView()
    private var onTap: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .clear
        backgroundColor = .clear
        contentView.isUserInteractionEnabled = true
        contentView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap)))

        configureRule(leadingRule)
        configureRule(trailingRule)

        flagView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            flagView.widthAnchor.constraint(equalToConstant: 18),
            flagView.heightAnchor.constraint(equalToConstant: 18)
        ])

        label.numberOfLines = 1
        label.font = UIFont.clawline(.timestamp, weight: .semibold)
        label.adjustsFontForContentSizeCategory = true
        label.setContentCompressionResistancePriority(.required, for: .horizontal)

        let labelGroup = UIStackView(arrangedSubviews: [flagView, label])
        labelGroup.axis = .horizontal
        labelGroup.spacing = 8
        labelGroup.alignment = .center

        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(leadingRule)
        stack.addArrangedSubview(labelGroup)
        stack.addArrangedSubview(trailingRule)
        contentView.addSubview(stack)

        // Activated only now: leadingRule/trailingRule need a common ancestor
        // (the stack, via addArrangedSubview above) before a cross-view
        // constraint between them can activate -- doing this earlier crashes
        // ("no common ancestor") the instant a divider is instantiated.
        leadingRule.widthAnchor.constraint(equalTo: trailingRule.widthAnchor).isActive = true

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Self.verticalPadding),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -Self.verticalPadding)
        ])

        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// - Parameters:
    ///   - isSegmentAnchorActive: current transient show-only-since-this-boundary
    ///     state, drives the accessibility value (grouping/boundary detection
    ///     itself is unaffected -- this cell only reports and toggles it).
    ///   - onTap: toggles segment-anchor; caller re-applies the snapshot.
    func configure(
        content: MarkerDividerContent,
        isDark: Bool,
        isSegmentAnchorActive: Bool,
        onTap: @escaping () -> Void
    ) {
        self.onTap = onTap
        let borderColor = isDark
            ? UIColor(red: 0.651, green: 0.565, blue: 0.439, alpha: 0.38)
            : UIColor(red: 0.486, green: 0.376, blue: 0.235, alpha: 0.30)
        let textColor = isDark
            ? UIColor(red: 0.718, green: 0.624, blue: 0.475, alpha: 1)
            : UIColor(red: 0.431, green: 0.333, blue: 0.208, alpha: 1)

        leadingRule.backgroundColor = borderColor
        trailingRule.backgroundColor = borderColor
        flagView.configure(isDark: isDark)
        label.attributedText = NSAttributedString(
            string: content.label,
            attributes: [.font: label.font as Any, .foregroundColor: textColor, .kern: 0.6]
        )
        accessibilityLabel = content.accessibilityLabel
        accessibilityValue = isSegmentAnchorActive ? "Showing only since this boundary" : nil
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        label.attributedText = nil
        accessibilityLabel = nil
        accessibilityValue = nil
        onTap = nil
    }

    /// Internal (not private) so the tap path is directly unit-testable
    /// without simulating a UIGestureRecognizer from the test target
    /// (same convention as SubstrateRunCollapseCell.handleTap()).
    @objc func handleTap() {
        onTap?()
    }

    static func itemID(before messageID: String) -> String {
        "\(itemIdPrefix)\(messageID)"
    }

    static func isMarkerDividerItemID(_ id: String) -> Bool {
        id.hasPrefix(itemIdPrefix)
    }

    private func configureRule(_ rule: UIView) {
        rule.translatesAutoresizingMaskIntoConstraints = false
        rule.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale).isActive = true
        rule.setContentHuggingPriority(.defaultLow, for: .horizontal)
        rule.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }
}

/// A full round waymark, not a speech bubble: no tail, fill, or outer shadow.
private final class MarkerFlagView: UIView {
    private let gradientLayer = CAGradientLayer()
    private let iconView = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        layer.addSublayer(gradientLayer)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.contentMode = .center
        iconView.tintColor = .white
        iconView.image = UIImage(
            systemName: "flag.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 8, weight: .semibold)
        )
        addSubview(iconView)
        NSLayoutConstraint.activate([
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        gradientLayer.frame = bounds
        gradientLayer.cornerRadius = min(bounds.width, bounds.height) / 2
    }

    func configure(isDark: Bool) {
        gradientLayer.type = .radial
        gradientLayer.startPoint = CGPoint(x: 0.5, y: 0.25)
        gradientLayer.endPoint = CGPoint(x: 1, y: 1)
        gradientLayer.colors = [
            UIColor(red: 0.886, green: 0.800, blue: 0.659, alpha: 1).cgColor,
            UIColor(red: 0.788, green: 0.663, blue: 0.490, alpha: 1).cgColor,
            UIColor(red: 0.592, green: 0.459, blue: 0.290, alpha: 1).cgColor
        ]
        gradientLayer.locations = [0, 0.6, 1]
        iconView.alpha = isDark ? 0.92 : 1
    }
}
