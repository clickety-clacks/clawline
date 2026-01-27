//
//  TypingIndicatorCell.swift
//  Clawline
//
//  Typing indicator shown while CLU is processing a message.
//

import Foundation
import UIKit

final class TypingIndicatorCell: UICollectionViewCell {
    static let reuseIdentifier = "TypingIndicatorCell"
    /// Fixed ID used in the diffable data source for the typing indicator item.
    static let itemId = "__typing_indicator__"

    private static let indicatorText = "   "
    private let containerView = MessageBubbleUIKitContainerView()
    private let dotsView = TypingDotsView()
    private var currentMetrics = ChatFlowTheme.Metrics(isCompact: true)

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .clear
        backgroundColor = .clear

        containerView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(containerView)
        NSLayoutConstraint.activate([
            containerView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            containerView.topAnchor.constraint(equalTo: contentView.topAnchor),
            containerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            containerView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])

        dotsView.translatesAutoresizingMaskIntoConstraints = true
        dotsView.isUserInteractionEnabled = false
        containerView.addSubview(dotsView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(message: Message,
                   presentation: MessagePresentation,
                   isCompact: Bool,
                   maxWidth: CGFloat,
                   isDark: Bool? = nil) {
        currentMetrics = ChatFlowTheme.Metrics(isCompact: isCompact)
        let effectiveIsDark = isDark ?? (traitCollection.userInterfaceStyle == .dark)
        dotsView.updateColor(ChatFlowUIKitTheme.palette(isDark: effectiveIsDark).ink)
        containerView.configure(
            message: message,
            presentation: presentation,
            failureReason: nil,
            isCompact: isCompact,
            maxWidth: maxWidth,
            isDark: isDark,
            onRequestExpand: nil,
            onRetry: nil
        )
        setNeedsLayout()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        stopAnimating()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let bubbleFrame = containerView.bubbleFrameInContainer()
        let dotSize = dotsView.dotSize
        let dotsSize = dotsView.intrinsicContentSize
        let headerHeight: CGFloat = 32
        let headerSpacing: CGFloat = 10
        let lineHeight = UIFont.systemFont(ofSize: currentMetrics.bodyFontSize).lineHeight
        let x = bubbleFrame.minX + currentMetrics.bubblePaddingHorizontal
        let y = bubbleFrame.minY
            + currentMetrics.bubblePaddingVertical
            + headerHeight
            + headerSpacing
            + (lineHeight - dotSize) / 2
        dotsView.frame = CGRect(x: x, y: y, width: dotsSize.width, height: dotsSize.height)
    }

    func startAnimating() {
        dotsView.startAnimating()
    }

    func stopAnimating() {
        dotsView.stopAnimating()
    }

    static func makeMessage(channelType: ChatChannelType) -> Message {
        Message(
            id: itemId,
            role: .assistant,
            content: indicatorText,
            timestamp: Date(),
            streaming: false,
            attachments: [],
            deviceId: nil,
            channelType: channelType
        )
    }

    static func makePresentation(metrics: ChatFlowTheme.Metrics) -> MessagePresentation {
        let text = indicatorText
        let wordCount = max(1, text.split(whereSeparator: { $0.isWhitespace || $0 == "." }).count)
        return MessagePresentation(
            parts: [.text(text)],
            wordCount: wordCount,
            hasTextualContent: true,
            isEmojiOnly: false,
            hasMediaOnly: false
        )
    }
}

private final class TypingDotsView: UIView {
    private let stack = UIStackView()
    private var dotViews: [UIView] = []
    private(set) var dotSize: CGFloat = 6
    private let dotSpacing: CGFloat = 6
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
