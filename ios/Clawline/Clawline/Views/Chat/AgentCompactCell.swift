//
//  AgentCompactCell.swift
//  Clawline
//
//  Cycle-3 Goal A, step 4. `.agent` classified messages (colleague DMs,
//  MessageKindClassifier) render as a compact full-width line in the
//  stream -- never the full "harbor" bubble. Per bubble-additions.html
//  Agent Lines spec: the compact line is the STREAM default; the harbor
//  bubble is reserved for the detail viewer (Goal B), opened by tapping
//  this line. Attribution comes only from the message's provenance
//  handle (MessageProvenance.origin), never inferred from content.
//

import UIKit

/// 22px harbor sphere avatar with the relay icon (two nodes, dotted route --
/// no stock SF Symbol matches, per bubble-additions.html "Avatar icons").
/// Visual language matches SubstrateStoneAvatarView/MarkerFlagView (radial
/// gradient, top-lit) but is its own independently-sized view, same
/// reasoning as SubstrateStoneAvatarView's note on AvatarCircleView.
final class AgentRelayAvatarView: UIView {
    private let gradientLayer = CAGradientLayer()
    private let iconView = AgentRelayIconView()

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
        // Harbor gradient (bubble-additions.html .avatar.agent):
        // #9DBACC -> #6E92A8 -> #46647A.
        gradientLayer.colors = [
            UIColor(red: 0.616, green: 0.729, blue: 0.800, alpha: 1).cgColor,
            UIColor(red: 0.431, green: 0.573, blue: 0.659, alpha: 1).cgColor,
            UIColor(red: 0.275, green: 0.392, blue: 0.478, alpha: 1).cgColor
        ]
        gradientLayer.locations = [0.0, 0.6, 1.0]
        layer.cornerRadius = size / 2
        layer.masksToBounds = true

        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)
        NSLayoutConstraint.activate([
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 12),
            iconView.heightAnchor.constraint(equalToConstant: 12)
        ])
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        gradientLayer.frame = bounds
    }
}

/// Two nodes joined by a dotted route (traffic between agents), traced from
/// the design's inline SVG (16x16 viewBox, circles r=2 at (4.5,11.5) and
/// (11.5,4.5), dashed connector).
private final class AgentRelayIconView: UIView {
    private let lineLayer = CAShapeLayer()
    private let nodeA = CAShapeLayer()
    private let nodeB = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        [lineLayer, nodeA, nodeB].forEach { layer.addSublayer($0) }
        lineLayer.strokeColor = UIColor.white.cgColor
        lineLayer.fillColor = nil
        lineLayer.lineCap = .round
        nodeA.fillColor = UIColor.white.cgColor
        nodeB.fillColor = UIColor.white.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = min(bounds.width, bounds.height) / 16
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * scale, y: y * scale) }
        let a = point(4.5, 11.5)
        let b = point(11.5, 4.5)
        let radius: CGFloat = 2 * scale
        nodeA.path = UIBezierPath(arcCenter: a, radius: radius, startAngle: 0, endAngle: .pi * 2, clockwise: true).cgPath
        nodeB.path = UIBezierPath(arcCenter: b, radius: radius, startAngle: 0, endAngle: .pi * 2, clockwise: true).cgPath
        let line = UIBezierPath()
        line.move(to: a)
        line.addLine(to: b)
        lineLayer.path = line.cgPath
        lineLayer.lineWidth = 1.4 * scale
        lineLayer.lineDashPattern = [0.1, 2.4].map { NSNumber(value: Double($0) * Double(scale)) }
    }
}

/// A single agent-compact row: full-width, chromeless at rest, a faint
/// harbor wash on hover/press. The whole line is a real button -- tapping
/// opens the message's full contents via Goal A's click-to-detail bridge
/// (MessageDetailAction.swift), never a full bubble in the stream itself.
final class AgentCompactCell: UICollectionViewCell {
    static let reuseIdentifier = "AgentCompactCell"
    static let leadingIndent: CGFloat = 12
    static let maximumPreviewLines = 3

    private enum Layout {
        static let avatarSize: CGFloat = 22
        static let avatarToText: CGFloat = 10
        static let textToMore: CGFloat = 4
        static let trailingInset: CGFloat = 12
        static let verticalInset: CGFloat = 5
        static let attributionToPreview: CGFloat = 2
    }

    private let washView = UIView()
    private let avatarView = AgentRelayAvatarView()
    private let senderLabel = UILabel()
    private let previewLabel = UILabel()
    private let moreLabel = UILabel()
    private var onTap: (() -> Void)?
    private var configuredSenderLine: String?
    private var configuredPreviewText: String?
    private var configuredIsDark = false
    /// Trackpad/mouse hover on iPad and Catalyst, from UIHoverGestureRecognizer.
    private var isHovered = false {
        didSet { updateWashVisibility() }
    }
    /// Touch-down press state, tracked directly rather than via
    /// UICollectionViewCell.isHighlighted: MessageFlowCollectionView's
    /// shouldHighlightItemAt returns false globally (a deliberate,
    /// collection-wide suppression covering every cell type, not something
    /// to touch for one cell), so isHighlighted never becomes true here.
    private var isPressed = false {
        didSet { updateWashVisibility() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .clear
        backgroundColor = .clear
        contentView.isUserInteractionEnabled = true
        contentView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap)))
        contentView.addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:))))

        // Faint harbor wash on hover/press (bubble-additions.html: 8-10%
        // alpha, 12px radius). Inserted below every other subview so it
        // never paints over the avatar/text/affordance.
        washView.translatesAutoresizingMaskIntoConstraints = false
        washView.isUserInteractionEnabled = false
        washView.layer.cornerRadius = 12
        washView.alpha = 0
        contentView.insertSubview(washView, at: 0)

        contentView.addSubview(avatarView)

        // Attribution has its own single-line slot. The body then receives
        // an independent one-to-three-line budget, so a long sender can
        // never consume every preview line at accessibility sizes.
        senderLabel.translatesAutoresizingMaskIntoConstraints = false
        senderLabel.adjustsFontForContentSizeCategory = true
        senderLabel.numberOfLines = 1
        senderLabel.lineBreakMode = .byTruncatingTail
        senderLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        senderLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        contentView.addSubview(senderLabel)

        previewLabel.translatesAutoresizingMaskIntoConstraints = false
        previewLabel.adjustsFontForContentSizeCategory = true
        previewLabel.numberOfLines = Self.maximumPreviewLines
        previewLabel.lineBreakMode = .byTruncatingTail
        previewLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        previewLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        contentView.addSubview(previewLabel)

        moreLabel.translatesAutoresizingMaskIntoConstraints = false
        moreLabel.text = "\u{22EF}"
        moreLabel.font = UIFont.clawline(.secondaryLabel, weight: .bold)
        moreLabel.adjustsFontForContentSizeCategory = true
        moreLabel.setContentHuggingPriority(.required, for: .horizontal)
        moreLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        contentView.addSubview(moreLabel)

        NSLayoutConstraint.activate([
            washView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            washView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            washView.topAnchor.constraint(equalTo: contentView.topAnchor),
            washView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            avatarView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Self.leadingIndent),
            avatarView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            senderLabel.leadingAnchor.constraint(equalTo: avatarView.trailingAnchor, constant: Layout.avatarToText),
            senderLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Layout.verticalInset),
            senderLabel.trailingAnchor.constraint(equalTo: moreLabel.leadingAnchor, constant: -Layout.textToMore),
            previewLabel.leadingAnchor.constraint(equalTo: senderLabel.leadingAnchor),
            previewLabel.topAnchor.constraint(equalTo: senderLabel.bottomAnchor, constant: Layout.attributionToPreview),
            previewLabel.trailingAnchor.constraint(equalTo: moreLabel.leadingAnchor, constant: -Layout.textToMore),
            previewLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -Layout.verticalInset),
            moreLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Layout.trailingInset),
            moreLabel.lastBaselineAnchor.constraint(equalTo: previewLabel.lastBaselineAnchor)
        ])

        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// - Parameters:
    ///   - senderLine: attribution only, e.g. "coder \u{00B7} gibson" -- built
    ///     from the message's provenance handle (`AgentCompactCell.displaySenderLine`),
    ///     never inferred from content.
    ///   - previewText: full stamp-stripped content. The label wraps it
    ///     naturally and truncates only after its third visible line.
    ///   - onTap: opens full contents via the click-to-detail bridge.
    func configure(senderLine: String, previewText: String, isDark: Bool, onTap: @escaping () -> Void) {
        self.onTap = onTap
        configuredSenderLine = senderLine
        configuredPreviewText = previewText
        configuredIsDark = isDark
        applyConfiguredContent()
        accessibilityLabel = "Agent report from \(senderLine). Open full content."
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        configuredSenderLine = nil
        configuredPreviewText = nil
        configuredIsDark = false
        senderLabel.text = nil
        previewLabel.text = nil
        accessibilityLabel = nil
        onTap = nil
        isHovered = false
        isPressed = false
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard previousTraitCollection?.preferredContentSizeCategory
            != traitCollection.preferredContentSizeCategory
        else { return }
        applyConfiguredContent()
    }

    private func applyConfiguredContent() {
        guard let configuredSenderLine, let configuredPreviewText else { return }
        let accent = ChatFlowUIKitTheme.agentAccent(isDark: configuredIsDark)
        senderLabel.text = configuredSenderLine
        senderLabel.font = UIFont.clawline(.senderName, compatibleWith: traitCollection)
        senderLabel.textColor = accent
        previewLabel.text = configuredPreviewText
        previewLabel.font = UIFont.clawline(.secondaryLabel, compatibleWith: traitCollection)
        previewLabel.textColor = ChatFlowUIKitTheme.textAgentLine(isDark: configuredIsDark)
        moreLabel.font = UIFont.clawline(
            .secondaryLabel,
            weight: .bold,
            compatibleWith: traitCollection
        )
        moreLabel.textColor = accent
        washView.backgroundColor = accent.withAlphaComponent(0.09)
    }

    /// The collection layout uses this exact cell geometry because its flow
    /// layout has self-sizing disabled. Keeping measurement here prevents a
    /// second, drifting definition of the three-line cap.
    static func measuredHeight(
        senderLine: String,
        previewText: String,
        rowWidth: CGFloat,
        compatibleWith traitCollection: UITraitCollection?
    ) -> CGFloat {
        let moreFont = UIFont.clawline(
            .secondaryLabel,
            weight: .bold,
            compatibleWith: traitCollection
        )
        let moreWidth = ceil(("\u{22EF}" as NSString).size(withAttributes: [.font: moreFont]).width)
        let textWidth = max(
            rowWidth
                - Self.leadingIndent
                - Layout.avatarSize
                - Layout.avatarToText
                - Layout.textToMore
                - moreWidth
                - Layout.trailingInset,
            1
        )
        let senderFont = UIFont.clawline(.senderName, compatibleWith: traitCollection)
        let previewFont = UIFont.clawline(.secondaryLabel, compatibleWith: traitCollection)
        let senderHeight = measuredLabelHeight(
            text: senderLine,
            font: senderFont,
            width: textWidth,
            lineLimit: 1
        )
        let previewHeight: CGFloat
        if previewText.isEmpty {
            previewHeight = 0
        } else {
            previewHeight = measuredLabelHeight(
                text: previewText,
                font: previewFont,
                width: textWidth,
                lineLimit: Self.maximumPreviewLines
            )
        }
        let attributionSpacing = senderHeight > 0 && previewHeight > 0
            ? Layout.attributionToPreview
            : 0
        let textHeight = senderHeight + attributionSpacing + previewHeight
        return ceil(max(Layout.avatarSize, textHeight) + (Layout.verticalInset * 2))
    }

    private static func measuredLabelHeight(
        text: String,
        font: UIFont,
        width: CGFloat,
        lineLimit: Int
    ) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let label = UILabel()
        label.font = font
        label.numberOfLines = lineLimit
        label.lineBreakMode = .byTruncatingTail
        label.text = text
        return ceil(label.sizeThatFits(
            CGSize(width: width, height: .greatestFiniteMagnitude)
        ).height)
    }

    private func updateWashVisibility() {
        washView.alpha = (isPressed || isHovered) ? 1 : 0
    }

    /// Internal (not private) so the press/hover wash is directly
    /// unit-testable, same convention as handleTap() below.
    var isWashVisibleForTesting: Bool {
        washView.alpha > 0
    }

    var contentTextForTesting: String? {
        guard let sender = senderLabel.text, let preview = previewLabel.text else { return nil }
        return preview.isEmpty ? sender : "\(sender) \(preview)"
    }

    var previewLineLimitForTesting: Int {
        previewLabel.numberOfLines
    }

    var previewLineBreakModeForTesting: NSLineBreakMode {
        previewLabel.lineBreakMode
    }

    @objc private func handleHover(_ recognizer: UIHoverGestureRecognizer) {
        switch recognizer.state {
        case .began, .changed:
            isHovered = true
        default:
            isHovered = false
        }
    }

    // UITapGestureRecognizer.cancelsTouchesInView (default true) sends
    // touchesBegan on real touch-down regardless, then touchesCancelled once
    // the tap recognizer takes over -- so this tracks the full press duration
    // correctly even though the gesture recognizer ultimately owns the touch.
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        isPressed = true
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        isPressed = false
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        isPressed = false
    }

    /// Internal (not private) so the tap path is directly unit-testable,
    /// same convention as SubstrateRunCollapseCell.handleTap().
    @objc func handleTap() {
        onTap?()
    }

    /// "coder:gibson" -> "coder \u{00B7} gibson". Pure reformatting of the
    /// wire-provided handle (MessageProvenanceOrigin.agent(handle:)) -- never
    /// invents or infers a name.
    static func displaySenderLine(forHandle handle: String) -> String {
        handle.replacingOccurrences(of: ":", with: " \u{00B7} ")
    }

}
