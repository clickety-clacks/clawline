//
//  SubstrateRunCollapseCell.swift
//  Clawline
//
//  Cycle-3 Goal A, step 2. Two or more consecutive `.substrate` classified
//  messages collapse to one line: "tightbeam · N notices ▾". The whole line
//  is a real button — tapping expands the stack in place, indented under the
//  shared waypoint (bubble-additions.html "Collapsed Run"). Grouping (which
//  messages form a run) is view-model DATA computed once per snapshot build;
//  expansion is TRANSIENT presentation state held by the collection view
//  controller, never persisted. Expanding/collapsing re-applies the diffable
//  snapshot; it never triggers a remeasure of unrelated bubble content.
//

import UIKit

final class SubstrateRunCollapseCell: UICollectionViewCell {
    static let reuseIdentifier = "SubstrateRunCollapseCell"

    private let avatarView = SubstrateStoneAvatarView()
    private let textLabel = UILabel()
    private let chevronView = UIImageView()
    private var onTap: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .clear
        backgroundColor = .clear
        contentView.isUserInteractionEnabled = true
        contentView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap)))

        avatarView.translatesAutoresizingMaskIntoConstraints = false
        avatarView.configure(style: .liveVoice)
        contentView.addSubview(avatarView)

        textLabel.translatesAutoresizingMaskIntoConstraints = false
        textLabel.numberOfLines = 1
        textLabel.font = UIFont.clawline(.secondaryLabel)
        textLabel.adjustsFontForContentSizeCategory = true
        contentView.addSubview(textLabel)

        chevronView.translatesAutoresizingMaskIntoConstraints = false
        chevronView.image = UIImage(systemName: "chevron.down", withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        chevronView.contentMode = .scaleAspectFit
        contentView.addSubview(chevronView)

        NSLayoutConstraint.activate([
            avatarView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: SubstrateRowCell.leadingIndent),
            avatarView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            textLabel.leadingAnchor.constraint(equalTo: avatarView.trailingAnchor, constant: 8),
            textLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            chevronView.leadingAnchor.constraint(equalTo: textLabel.trailingAnchor, constant: 4),
            chevronView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            chevronView.widthAnchor.constraint(equalToConstant: 12),
            chevronView.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -12),
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
    ///   - noticeCount: number of collapsed rows this run represents.
    ///   - isExpanded: current transient expansion state, drives the chevron
    ///     rotation and the accessibility expanded value. When expanded, this
    ///     cell is not shown (the snapshot substitutes the individual rows
    ///     instead) — configure(isExpanded: true) exists for the brief
    ///     transition frame while the snapshot re-applies.
    ///   - onTap: toggles expansion; caller re-applies the snapshot.
    func configure(noticeCount: Int, isExpanded: Bool, isDark: Bool, onTap: @escaping () -> Void) {
        self.onTap = onTap
        let noun = noticeCount == 1 ? "notice" : "notices"
        let leadFont = UIFont.clawline(.secondaryLabel, weight: .semibold)
        let bodyFont = UIFont.clawline(.secondaryLabel)
        let textColor = ChatFlowUIKitTheme.textSubstrate(isDark: isDark)
        let text = NSMutableAttributedString(
            string: "tightbeam",
            attributes: [.font: leadFont, .foregroundColor: textColor, .kern: 0.3]
        )
        text.append(NSAttributedString(
            string: " \u{00B7} \(noticeCount) \(noun)",
            attributes: [.font: bodyFont, .foregroundColor: textColor]
        ))
        textLabel.attributedText = text
        chevronView.tintColor = textColor
        chevronView.transform = isExpanded ? CGAffineTransform(rotationAngle: .pi) : .identity

        accessibilityLabel = "tightbeam, \(noticeCount) \(noun)"
        accessibilityTraits = .button
        accessibilityValue = isExpanded ? "Expanded" : "Collapsed"
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        textLabel.attributedText = nil
        onTap = nil
    }

    /// Internal (not private) so the tap path is directly unit-testable
    /// without simulating a UIGestureRecognizer from the test target.
    @objc func handleTap() {
        onTap?()
    }
}
