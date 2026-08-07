//
//  SubstrateRowCell.swift
//  Clawline
//
//  Cycle-3 Goal A, step 2. Chromeless ghost-row rendering for `.substrate`
//  classified messages (MessageKindClassifier). Full-width, no bubble, no
//  border, no shadow, no hover lift — "the ground is not an object"
//  (bubble-additions.html Substrate spec).
//
//  Record sub-style: the design defines a distinct "record voice" (ledger
//  check icon, event-name-leads formatting, no "tightbeam" source prefix) for
//  record-shaped substrate rows (assignment opened, progress filed, etc).
//  The design doc marks this sub-style OPTIONAL ("a client may render records
//  identically to the live voice"), and today there is no reliable wire
//  signal that distinguishes a record-shaped substrate message from a
//  live-voice one (Goal A step-1 observability report: no structured
//  discriminator field exists). `SubstrateRowStyle` is therefore modeled as a
//  seam — `.record` renders correctly when passed in — but no call site
//  classifies a message as `.record` yet; every substrate row renders
//  `.liveVoice` today. Wire a `.record` classifier once a reliable signal
//  exists; do not guess one from message text.
//

import UIKit

enum SubstrateRowStyle: Equatable {
    case liveVoice
    case record
}

/// 22px stone sphere avatar shared by substrate live-voice and record rows.
/// Visual language matches AvatarCircleView (radial gradient, top-lit) but is
/// a distinct, independently-sized view — AvatarCircleView is fixed at 32px
/// with a lettered role glyph (see its "avatar is sacred" note) and is not
/// parameterized for icon content or alternate sizes.
final class SubstrateStoneAvatarView: UIView {
    private let gradientLayer = CAGradientLayer()
    private let iconView = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        let size: CGFloat = 22
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size),
            heightAnchor.constraint(equalToConstant: size)
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .vertical)

        layer.insertSublayer(gradientLayer, at: 0)
        gradientLayer.type = .radial
        gradientLayer.startPoint = CGPoint(x: 0.5, y: 0.25)
        gradientLayer.endPoint = CGPoint(x: 1.0, y: 1.0)
        // Stone gradient (bubble-additions.html): #BFB3A4 -> #9A8E7E -> #756A5B.
        gradientLayer.colors = [
            UIColor(red: 0.749, green: 0.702, blue: 0.643, alpha: 1).cgColor,
            UIColor(red: 0.604, green: 0.557, blue: 0.494, alpha: 1).cgColor,
            UIColor(red: 0.459, green: 0.416, blue: 0.357, alpha: 1).cgColor
        ]
        gradientLayer.locations = [0.0, 0.6, 1.0]
        layer.cornerRadius = size / 2
        layer.masksToBounds = true

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.tintColor = .white
        iconView.contentMode = .scaleAspectFit
        addSubview(iconView)
        NSLayoutConstraint.activate([
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 12),
            iconView.heightAnchor.constraint(equalToConstant: 12)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        gradientLayer.frame = bounds
    }

    func configure(style: SubstrateRowStyle) {
        let config = UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        switch style {
        case .liveVoice:
            iconView.image = UIImage(systemName: "dot.radiowaves.left.and.right", withConfiguration: config)
            accessibilityLabel = "Substrate"
        case .record:
            iconView.image = UIImage(systemName: "checkmark", withConfiguration: config)
            accessibilityLabel = "Substrate record"
        }
    }
}

/// A single substrate ghost row: one classified message rendered chromeless,
/// full width, 13pt text. Not interactive — only the collapsed-run summary
/// row (SubstrateRunCollapseCell) is a tap target; an individual row (lone
/// message or an expanded member of a run) is static text.
final class SubstrateRowCell: UICollectionViewCell {
    static let reuseIdentifier = "SubstrateRowCell"
    static let leadingIndent: CGFloat = 12
    static let expandedStackIndent: CGFloat = 30

    private let avatarView = SubstrateStoneAvatarView()
    private let textLabel = UILabel()
    private var indentConstraint: NSLayoutConstraint?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .clear
        backgroundColor = .clear

        avatarView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(avatarView)

        textLabel.translatesAutoresizingMaskIntoConstraints = false
        textLabel.numberOfLines = 0
        textLabel.font = UIFont.clawline(.secondaryLabel)
        textLabel.adjustsFontForContentSizeCategory = true
        contentView.addSubview(textLabel)

        let indent = avatarView.leadingAnchor.constraint(
            equalTo: contentView.leadingAnchor,
            constant: Self.leadingIndent
        )
        indentConstraint = indent
        NSLayoutConstraint.activate([
            indent,
            avatarView.centerYAnchor.constraint(equalTo: textLabel.centerYAnchor),
            textLabel.leadingAnchor.constraint(equalTo: avatarView.trailingAnchor, constant: 8),
            textLabel.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -12),
            textLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
            textLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6)
        ])

        isAccessibilityElement = true
        accessibilityTraits = .staticText
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// - Parameters:
    ///   - leadLabel: "tightbeam" for live voice, the event name for records
    ///     (bubble-additions.html: lead label is 600 weight, 0.3px tracking).
    ///   - detail: the rest of the line, following the lead label's " · ".
    ///   - style: live-voice or record (see the type-level note on why
    ///     `.record` has no producer today).
    ///   - isDark: current theme.
    ///   - isIndentedUnderRun: true when this row is a member of an EXPANDED
    ///     run, stacked under the shared waypoint (bubble-additions.html
    ///     "Collapsed Run" — expanded rows indent under the run's avatar).
    func configure(
        leadLabel: String,
        detail: String,
        style: SubstrateRowStyle,
        isDark: Bool,
        isIndentedUnderRun: Bool
    ) {
        avatarView.configure(style: style)
        avatarView.isHidden = isIndentedUnderRun
        indentConstraint?.constant = isIndentedUnderRun ? Self.expandedStackIndent : Self.leadingIndent

        let leadFont = UIFont.clawline(.secondaryLabel, weight: .semibold)
        let bodyFont = UIFont.clawline(.secondaryLabel)
        let textColor = ChatFlowUIKitTheme.textSubstrate(isDark: isDark)
        let lead = NSMutableAttributedString(
            string: leadLabel,
            attributes: [
                .font: leadFont,
                .foregroundColor: textColor,
                .kern: 0.3
            ]
        )
        let rest = NSAttributedString(
            string: " \u{00B7} \(detail)",
            attributes: [.font: bodyFont, .foregroundColor: textColor]
        )
        lead.append(rest)
        textLabel.attributedText = lead
        accessibilityLabel = "\(leadLabel). \(detail)"
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        textLabel.attributedText = nil
        avatarView.isHidden = false
        indentConstraint?.constant = Self.leadingIndent
    }
}
