//
//  SubstrateRowCell.swift
//  Clawline
//
//  Cycle-3 Goal A, step 2. Chromeless ghost-row rendering for `.substrate`
//  classified messages (MessageKindClassifier). Bounded card-flow width, no bubble, no
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
//  discriminator field exists). `SubstrateRowHeader.record` is therefore
//  modeled as a seam — it renders correctly when passed in — but no call site
//  classifies a message as `.record` yet; every substrate row renders
//  live voice today. Wire a `.record` classifier once a reliable signal
//  exists; do not guess one from message text.
//

import UIKit

enum SubstrateRowHeader: Equatable {
    case tightbeam
    case process(name: String)
    case record(eventName: String)

    private static let primarySourceName = "Tightbeam"
    private static let knownProcessSourceNames = [
        "anthropic": "Anthropic",
        "chatgpt": "ChatGPT",
        "ci": "CI",
        "claude": "Claude",
        "codex": "Codex",
        "gemini": "Gemini",
        "github": "GitHub",
        "gitlab": "GitLab",
        "openai": "OpenAI"
    ]

    /// Resolves the live-voice taxonomy only from durable sender provenance.
    /// `process:tightbeam` is the substrate itself. Every other meaningful
    /// process name remains a process delivery and never borrows Tightbeam's
    /// primary identity.
    static func liveVoice(for origin: MessageProvenanceOrigin?) -> Self {
        guard case let .process(name)? = origin else { return .tightbeam }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !isTightbeamOrigin(origin) else {
            return .tightbeam
        }
        let displayName = knownProcessSourceNames[trimmedName.lowercased()] ?? trimmedName
        return .process(name: displayName)
    }

    static func isTightbeamOrigin(_ origin: MessageProvenanceOrigin?) -> Bool {
        guard case let .process(name)? = origin else { return false }
        return name.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(primarySourceName) == .orderedSame
    }

    var leadLabel: String {
        switch self {
        case .tightbeam:
            return Self.primarySourceName
        case .process(let name):
            return "Process • \(name)"
        case .record(let eventName):
            return eventName
        }
    }

    var avatarSystemName: String {
        switch self {
        case .tightbeam:
            return "gearshape.fill"
        case .process:
            return "dot.radiowaves.left.and.right"
        case .record:
            return "checkmark"
        }
    }

    var avatarAccessibilityLabel: String {
        switch self {
        case .tightbeam:
            return "Tightbeam substrate"
        case .process:
            return "Process delivery"
        case .record:
            return "Substrate record"
        }
    }

    var accessibilityPrefix: String {
        switch self {
        case .tightbeam:
            return "Notice from Tightbeam substrate"
        case .process(let name):
            return "Process delivery from \(name)"
        case .record(let eventName):
            return "Event: \(eventName)"
        }
    }
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

    func configure(header: SubstrateRowHeader) {
        let config = UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        iconView.image = UIImage(systemName: header.avatarSystemName, withConfiguration: config)
        accessibilityLabel = header.avatarAccessibilityLabel
    }
}

/// A single substrate ghost row: one classified message rendered chromeless
/// at the shared card-flow width, in 13pt text. Cycle-3 Goal A step 5: the whole row is a real
/// button -- tapping opens the message's full contents via the
/// click-to-detail bridge (MessageDetailAction.swift), same contract as
/// SubstrateRunCollapseCell's tap-to-expand and AgentCompactCell's
/// tap-to-detail. This applies whether the row is a lone message or an
/// expanded member of a run; only the collapsed-run SUMMARY row
/// (SubstrateRunCollapseCell) has the separate expand/collapse tap.
final class SubstrateRowCell: UICollectionViewCell {
    static let reuseIdentifier = "SubstrateRowCell"
    static let leadingIndent: CGFloat = 12
    static let expandedStackIndent: CGFloat = 30
    private static let avatarSize: CGFloat = 22
    private static let avatarToText: CGFloat = 8
    private static let trailingInset: CGFloat = 12
    private static let verticalInset: CGFloat = 6

    private let avatarView = SubstrateStoneAvatarView()
    private let textLabel = UILabel()
    private var indentConstraint: NSLayoutConstraint?
    private var onTap: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .clear
        backgroundColor = .clear
        contentView.isUserInteractionEnabled = true
        contentView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap)))

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
        accessibilityTraits = .button
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// - Parameters:
    ///   - header: the provenance-derived delivery identity for live voice, or
    ///     the event name for records
    ///     (bubble-additions.html: lead label is 600 weight, 0.3px tracking).
    ///   - detail: the rest of the line, following the lead label's " · ".
    ///   - isDark: current theme.
    ///   - isIndentedUnderRun: true when this row is a member of an EXPANDED
    ///     run, stacked under the shared waypoint (bubble-additions.html
    ///     "Collapsed Run" — expanded rows indent under the run's avatar).
    ///   - onTap: opens full contents via the click-to-detail bridge.
    func configure(
        header: SubstrateRowHeader,
        detail: String,
        isDark: Bool,
        isIndentedUnderRun: Bool,
        onTap: @escaping () -> Void
    ) {
        self.onTap = onTap
        avatarView.configure(header: header)
        avatarView.isHidden = isIndentedUnderRun
        indentConstraint?.constant = isIndentedUnderRun ? Self.expandedStackIndent : Self.leadingIndent

        let leadLabel = header.leadLabel
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
        // Leads with the kind (bubble-additions.html: "Screen reader labels
        // lead with the kind" -- "notice from tightbeam substrate" for live
        // voice, "event: <name>" for records), same requirement AgentCompactCell
        // already meets with "Agent report from <sender>. Open full content."
        accessibilityLabel = "\(header.accessibilityPrefix). \(detail). Open full content."
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        textLabel.attributedText = nil
        avatarView.isHidden = false
        indentConstraint?.constant = Self.leadingIndent
        onTap = nil
    }

    /// Internal (not private) so the tap path is directly unit-testable,
    /// same convention as SubstrateRunCollapseCell.handleTap().
    @objc func handleTap() {
        onTap?()
    }

    /// Matches the multiline label and waypoint constraints above. The
    /// collection layout has self-sizing disabled, so its card-flow width and
    /// Dynamic Type traits must feed this same measurement seam.
    static func measuredHeight(
        header: SubstrateRowHeader,
        detail: String,
        rowWidth: CGFloat,
        isIndentedUnderRun: Bool,
        compatibleWith traitCollection: UITraitCollection?
    ) -> CGFloat {
        let leadingInset = isIndentedUnderRun ? expandedStackIndent : leadingIndent
        let textWidth = max(
            rowWidth - leadingInset - avatarSize - avatarToText - trailingInset,
            1
        )
        let leadFont = UIFont.clawline(
            .secondaryLabel,
            weight: .semibold,
            compatibleWith: traitCollection
        )
        let bodyFont = UIFont.clawline(.secondaryLabel, compatibleWith: traitCollection)
        let text = NSMutableAttributedString(
            string: header.leadLabel,
            attributes: [.font: leadFont]
        )
        text.append(NSAttributedString(string: " \u{00B7} \(detail)", attributes: [.font: bodyFont]))

        let label = UILabel()
        label.numberOfLines = 0
        label.attributedText = text
        let textHeight = label.sizeThatFits(
            CGSize(width: textWidth, height: .greatestFiniteMagnitude)
        ).height
        return ceil(max(avatarSize, textHeight) + (verticalInset * 2))
    }
}
