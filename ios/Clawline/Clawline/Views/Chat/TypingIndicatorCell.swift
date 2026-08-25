//
//  TypingIndicatorCell.swift
//  Clawline
//
//  Typing indicator shown while CLU is processing a message.
//

import Foundation
import OSLog
import UIKit

final class TypingIndicatorCell: UICollectionViewCell {
    static let reuseIdentifier = "TypingIndicatorCell"
    /// Fixed ID used in the diffable data source for the typing indicator item.
    static let itemId = "__typing_indicator__"
    static let bubbleWidth: CGFloat = MessageBubbleGeometry.typingBubbleWidth
    static let bubbleHeight: CGFloat = MessageBubbleGeometry.typingBubbleHeight
    static let bubblePaddingScale: CGFloat = MessageBubbleGeometry.typingBubblePaddingScale
    static let progressLabelWidth: CGFloat = MessageBubbleGeometry.typingProgressLabelWidth

    private static let indicatorText = ""
    private let containerView = MessageBubbleUIKitContainerView()
    private let dotsView = TypingDotsView()
    private let progressStack = UIStackView()
    private let progressLabel = UILabel()
    private let toolActivityPill = ToolActivityPillView()
#if os(visionOS)
    private let spatialTapButton = UIButton(type: .custom)
#endif
    private var currentMetrics = ChatFlowTheme.Metrics(isCompact: true)
    private let showsHeader = false
    private let paddingScale: CGFloat = bubblePaddingScale
    private var onTap: (() -> Void)?
    private let diagnosticLogger = Logger(subsystem: "co.clicketyclacks.Clawline", category: "T217TypingCancel")

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .clear
        backgroundColor = .clear
        contentView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap)))

        progressStack.axis = .vertical
        progressStack.alignment = .center
        progressStack.spacing = 9
        progressStack.isUserInteractionEnabled = false
        progressStack.addArrangedSubview(dotsView)

        progressLabel.font = .preferredFont(forTextStyle: .caption1)
        progressLabel.adjustsFontForContentSizeCategory = true
        progressLabel.textAlignment = .center
        progressLabel.numberOfLines = 0
        progressLabel.lineBreakMode = .byWordWrapping
        progressLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        progressStack.addArrangedSubview(progressLabel)
        progressLabel.widthAnchor.constraint(equalToConstant: Self.progressLabelWidth).isActive = true

        progressStack.addArrangedSubview(toolActivityPill)
        toolActivityPill.widthAnchor.constraint(lessThanOrEqualToConstant: Self.progressLabelWidth).isActive = true

        containerView.translatesAutoresizingMaskIntoConstraints = false
        containerView.isUserInteractionEnabled = false
        contentView.addSubview(containerView)
        NSLayoutConstraint.activate([
            containerView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            containerView.topAnchor.constraint(equalTo: contentView.topAnchor),
            containerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            containerView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
#if os(visionOS)
        spatialTapButton.translatesAutoresizingMaskIntoConstraints = false
        spatialTapButton.backgroundColor = .clear
        spatialTapButton.isOpaque = false
        spatialTapButton.accessibilityLabel = "Open council controls"
        spatialTapButton.accessibilityTraits.insert(.button)
        spatialTapButton.addTarget(self, action: #selector(handleTap), for: .primaryActionTriggered)
        contentView.addSubview(spatialTapButton)
        NSLayoutConstraint.activate([
            spatialTapButton.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            spatialTapButton.topAnchor.constraint(equalTo: contentView.topAnchor),
            spatialTapButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            spatialTapButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
#endif
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(message: Message,
                   presentation: MessagePresentation,
                   isCompact: Bool,
                   maxWidth: CGFloat,
                   isDark: Bool? = nil,
                   progress: LiveAgentProgress? = nil,
                   progressSummary: String? = nil,
                   onTap: (() -> Void)? = nil) {
        self.onTap = onTap
        let diagnosticMessage = "T217DIAG cell_configure build=\(Self.diagnosticBuild) session=\(message.sessionKey) hasCallback=\(onTap != nil) bounds=\(String(describing: self.bounds)) frame=\(String(describing: self.frame)) maxWidth=\(maxWidth)"
        print(diagnosticMessage)
        diagnosticLogger.notice(
            "T217DIAG cell_configure build=\(Self.diagnosticBuild, privacy: .public) session=\(message.sessionKey, privacy: .public) hasCallback=\(onTap != nil, privacy: .public) bounds=\(String(describing: self.bounds), privacy: .public) frame=\(String(describing: self.frame), privacy: .public) maxWidth=\(maxWidth, privacy: .public)"
        )
        currentMetrics = ChatFlowTheme.Metrics(isCompact: isCompact)
        let effectiveIsDark = isDark ?? (traitCollection.userInterfaceStyle == .dark)
        let palette = ChatFlowUIKitTheme.palette(isDark: effectiveIsDark)
        dotsView.updateColor(palette.ink)
        let trimmedProgress = (progress?.summary ?? progressSummary)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let toolActivity = progress?.toolActivity
        progressLabel.text = trimmedProgress
        progressLabel.isHidden = toolActivity != nil || (trimmedProgress?.isEmpty ?? true)
        progressLabel.textColor = palette.ink.withAlphaComponent(0.82)
        toolActivityPill.configure(toolActivity, palette: palette)
        containerView.configure(
            message: message,
            stream: .personal,
            presentation: presentation,
            sendIndicatorState: nil,
            isCompact: isCompact,
            maxWidth: maxWidth,
            showsHeader: showsHeader,
            paddingScale: paddingScale,
            minWidthOverride: Self.bubbleWidth,
            maxWidthOverride: Self.bubbleWidth,
            minHeightOverride: Self.height(progress: progress, progressSummary: trimmedProgress),
            isDark: isDark,
            onRequestExpand: nil,
            onRequestLayout: nil,
            onInteractiveCallback: nil,
            onInsertIntoPrompt: nil,
            onReferenceMessage: nil,
            onResend: nil
        )
        containerView.setCenteredOverlayView(progressStack)
        if let toolActivity {
            accessibilityLabel = toolActivity.accessibilityLabel
        } else if let trimmedProgress, !trimmedProgress.isEmpty {
            accessibilityLabel = trimmedProgress
        } else {
            accessibilityLabel = "Assistant is working"
        }
        accessibilityTraits = onTap == nil ? .staticText : .button
        setNeedsLayout()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        stopAnimating()
        containerView.setCenteredOverlayView(nil)
        progressLabel.text = nil
        progressLabel.isHidden = true
        toolActivityPill.configure(nil, palette: ChatFlowUIKitTheme.palette(isDark: false))
        onTap = nil
    }

    @objc private func handleTap() {
        let diagnosticMessage = "T217DIAG cell_tap build=\(Self.diagnosticBuild) hasCallback=\(self.onTap != nil) bounds=\(String(describing: self.bounds)) frame=\(String(describing: self.frame))"
        print(diagnosticMessage)
        diagnosticLogger.notice(
            "T217DIAG cell_tap build=\(Self.diagnosticBuild, privacy: .public) hasCallback=\(self.onTap != nil, privacy: .public) bounds=\(String(describing: self.bounds), privacy: .public) frame=\(String(describing: self.frame), privacy: .public)"
        )
        onTap?()
    }

    func startAnimating() {
        dotsView.startAnimating()
    }

    func stopAnimating() {
        dotsView.stopAnimating()
    }

    func renderedBubbleFrame(in coordinateSpace: UICoordinateSpace?) -> CGRect {
        layoutIfNeeded()
        let bubbleFrame = containerView.bubbleFrameInContainer()
        if let coordinateSpace {
            return containerView.convert(bubbleFrame, to: coordinateSpace)
        }
        return containerView.convert(bubbleFrame, to: nil)
    }

    static func makeMessage(sessionKey: String) -> Message {
        return Message(
            id: itemId,
            role: .assistant,
            content: indicatorText,
            timestamp: Date(),
            streaming: false,
            attachments: [],
            deviceId: nil,
            sessionKey: sessionKey
        )
    }

    static func makePresentation(metrics: ChatFlowTheme.Metrics) -> MessagePresentation {
        return MessagePresentation(
            parts: [],
            wordCount: 0,
            hasTextualContent: false,
            isEmojiOnly: false,
            hasMediaOnly: false,
            detectedURLs: [],
            detectedURLCount: 0,
            hasSingleURL: false
        )
    }

    static func height(progressSummary: String?, font: UIFont = .preferredFont(forTextStyle: .caption1)) -> CGFloat {
        MessageBubbleGeometry.typingHeight(progressSummary: progressSummary, font: font)
    }

    static func height(progress: LiveAgentProgress?,
                       progressSummary: String? = nil,
                       font: UIFont = .preferredFont(forTextStyle: .caption1)) -> CGFloat {
        let summary = progress?.summary ?? progressSummary
        let baseHeight = height(progressSummary: summary, font: font)
        return progress?.toolActivity == nil ? baseHeight : baseHeight + ToolActivityPillView.verticalPadding
    }

    var isShowingToolActivityPillForTests: Bool { !toolActivityPill.isHidden }
    var toolVerbForTests: String? { toolActivityPill.verbText }
    var toolArgumentsForTests: String? { toolActivityPill.argumentsText }
    var toolVerbFontForTests: UIFont? { toolActivityPill.verbFont }
    var toolArgumentsFontForTests: UIFont? { toolActivityPill.argumentsFont }
}

private extension LiveToolActivity {
    var accessibilityLabel: String {
        guard let argumentsSummary else { return verb }
        return "\(verb), \(argumentsSummary)"
    }
}

private final class ToolActivityPillView: UIView {
    static let verticalPadding: CGFloat = 8

    private let stack = UIStackView()
    private let verbLabel = UILabel()
    private let argumentsLabel = UILabel()

    var verbText: String? { verbLabel.text }
    var argumentsText: String? { argumentsLabel.text }
    var verbFont: UIFont? { verbLabel.font }
    var argumentsFont: UIFont? { argumentsLabel.font }

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        layer.cornerRadius = 10
        layer.cornerCurve = .continuous
        clipsToBounds = true
        isAccessibilityElement = false
        isHidden = true

        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 6

        verbLabel.font = .preferredFont(forTextStyle: .caption1).bold()
        verbLabel.adjustsFontForContentSizeCategory = true
        verbLabel.numberOfLines = 1
        verbLabel.lineBreakMode = .byTruncatingTail
        verbLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        argumentsLabel.font = .preferredFont(forTextStyle: .caption1)
        argumentsLabel.adjustsFontForContentSizeCategory = true
        argumentsLabel.numberOfLines = 1
        argumentsLabel.lineBreakMode = .byTruncatingTail
        argumentsLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        stack.addArrangedSubview(verbLabel)
        stack.addArrangedSubview(argumentsLabel)
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: Self.verticalPadding / 2),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.verticalPadding / 2)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(_ activity: LiveToolActivity?, palette: ChatFlowUIKitTheme.Palette) {
        guard let activity else {
            verbLabel.text = nil
            argumentsLabel.text = nil
            argumentsLabel.isHidden = true
            isHidden = true
            return
        }
        verbLabel.text = activity.verb
        verbLabel.textColor = palette.terracotta
        argumentsLabel.text = activity.argumentsSummary
        argumentsLabel.textColor = palette.ink.withAlphaComponent(0.82)
        argumentsLabel.isHidden = activity.argumentsSummary == nil
        backgroundColor = palette.borderSubtle
        isHidden = false
    }
}

private extension UIFont {
    func bold() -> UIFont {
        guard let descriptor = fontDescriptor.withSymbolicTraits(.traitBold) else { return self }
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}

private extension TypingIndicatorCell {
    static var diagnosticBuild: String {
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        return "T217-typing-cancel-\(build)"
    }
}

private final class TypingDotsView: UIView {
    private let stack = UIStackView()
    private var dotViews: [UIView] = []
    private(set) var dotSize: CGFloat = 7
    private let dotSpacing: CGFloat = 4
    private let bounceHeight: CGFloat = 4
    private let duration: CFTimeInterval = 0.9
    private var isAnimating = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear

        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = dotSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        for _ in 0..<3 {
            let dot = UIView()
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.layer.cornerRadius = dotSize / 2
            dot.backgroundColor = .label
            NSLayoutConstraint.activate([
                dot.widthAnchor.constraint(equalToConstant: dotSize),
                dot.heightAnchor.constraint(equalToConstant: dotSize)
            ])
            stack.addArrangedSubview(dot)
            dotViews.append(dot)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: (dotSize * 3) + (dotSpacing * 2), height: dotSize)
    }

    func updateColor(_ color: UIColor) {
        for dot in dotViews {
            dot.backgroundColor = color
        }
    }

    func startAnimating() {
        guard !isAnimating else { return }
        isAnimating = true
        let baseTime = CACurrentMediaTime()
        for (index, dot) in dotViews.enumerated() {
            let animation = CAKeyframeAnimation(keyPath: "transform.translation.y")
            animation.values = [0, -bounceHeight, 0]
            animation.keyTimes = [0, 0.4, 1]
            animation.duration = duration
            animation.repeatCount = .infinity
            animation.timingFunctions = [
                CAMediaTimingFunction(name: .easeInEaseOut),
                CAMediaTimingFunction(name: .easeInEaseOut)
            ]
            animation.beginTime = baseTime + (Double(index) * 0.12)
            animation.isRemovedOnCompletion = false
            dot.layer.add(animation, forKey: "typingBounce")
        }
    }

    func stopAnimating() {
        guard isAnimating else { return }
        isAnimating = false
        for dot in dotViews {
            dot.layer.removeAnimation(forKey: "typingBounce")
            dot.transform = .identity
        }
    }
}
