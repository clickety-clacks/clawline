//
//  ProvenanceChipView.swift
//  Clawline
//
//  Header chip that marks a `role=user` message as wake-delivered rather than
//  typed on this device. See spec §T-D and MessageProvenance.
//

import UIKit

/// A small pill shown in the message header in place of the "You" sender label
/// when a message carries a recognized provenance origin. The chip is dumb: the
/// bubble supplies already-resolved text and colors so this view owns no theme
/// or classification logic.
final class ProvenanceChipView: UIView {
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureHierarchy()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configureHierarchy() {
        translatesAutoresizingMaskIntoConstraints = false
        layer.cornerRadius = 8
        layer.cornerCurve = .continuous
        clipsToBounds = true
        setContentHuggingPriority(.defaultHigh, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)

        label.translatesAutoresizingMaskIntoConstraints = false
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        label.adjustsFontForContentSizeCategory = true
        label.font = UIFont.clawline(.senderName)
        addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2)
        ])

        isAccessibilityElement = true
        accessibilityTraits = .staticText
    }

    /// Configure the chip with resolved presentation text and colors.
    /// - Parameters:
    ///   - text: the chip label (glyph already prefixed when applicable).
    ///   - textColor: foreground color for the label.
    ///   - fillColor: pill background color.
    func configure(text: String, textColor: UIColor, fillColor: UIColor) {
        label.text = text
        label.textColor = textColor
        backgroundColor = fillColor
        accessibilityLabel = "From \(text)"
    }

    var textForTests: String? { label.text }
}
