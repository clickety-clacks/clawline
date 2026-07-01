//
//  PendingTextAttachment.swift
//  Clawline
//
//  Created by Codex on 1/15/26.
//

import UIKit

final class PendingTextAttachment: NSTextAttachment {
    private enum Metrics {
        static let maxHeight: CGFloat = 44
        static let maxWidth: CGFloat = 72
        static let verticalOffset: CGFloat = -6
    }

    let pendingId: UUID
    private let accessibilityText: String

    init(id: UUID, thumbnail: UIImage, accessibilityLabel: String) {
        self.pendingId = id
        self.accessibilityText = accessibilityLabel
        super.init(data: nil, ofType: nil)
        image = thumbnail
        bounds = PendingTextAttachment.makeBounds(for: thumbnail)
        isAccessibilityElement = true
        self.accessibilityLabel = accessibilityText
    }

    required init?(coder: NSCoder) {
        guard let id = coder.decodeObject(forKey: "pendingId") as? UUID else {
            return nil
        }
        self.pendingId = id
        self.accessibilityText = coder.decodeObject(forKey: "accessibilityText") as? String ?? "Attachment"
        super.init(coder: coder)
        if let image = image {
            bounds = PendingTextAttachment.makeBounds(for: image)
        }
        isAccessibilityElement = true
        self.accessibilityLabel = accessibilityText
    }

    override func encode(with coder: NSCoder) {
        coder.encode(pendingId, forKey: "pendingId")
        coder.encode(accessibilityText, forKey: "accessibilityText")
        super.encode(with: coder)
    }

    private static func makeBounds(for image: UIImage) -> CGRect {
        // Preserve aspect ratio: fit inside a max height + max width box.
        // This avoids squashing wide/tall thumbnails in the compose bar (#55).
        let imageSize = image.size
        guard imageSize.width > 0, imageSize.height > 0 else {
            return CGRect(x: 0, y: Metrics.verticalOffset, width: Metrics.maxHeight, height: Metrics.maxHeight)
        }

        let heightScale = Metrics.maxHeight / imageSize.height
        let widthScale = Metrics.maxWidth / imageSize.width
        let scale = min(heightScale, widthScale, 1)
        let size = CGSize(width: floor(imageSize.width * scale), height: floor(imageSize.height * scale))
        return CGRect(x: 0, y: Metrics.verticalOffset, width: max(1, size.width), height: max(1, size.height))
    }
}

final class MessageReferenceTextAttachment: NSTextAttachment {
    private enum Metrics {
        static let height: CGFloat = 30
        static let maxWidth: CGFloat = 160
        static let minWidth: CGFloat = 84
        static let verticalOffset: CGFloat = -7
        static let horizontalPadding: CGFloat = 12
        static let iconSize: CGFloat = 12
        static let iconSpacing: CGFloat = 5
    }

    let referenceId: UUID
    private let accessibilityText: String

    init(reference: PendingMessageReference) {
        self.referenceId = reference.id
        self.accessibilityText = "Referenced message, \(reference.tokenLabel)"
        super.init(data: nil, ofType: nil)
        image = Self.makeTokenImage(label: reference.tokenLabel)
        if let image {
            bounds = Self.makeBounds(for: image)
        }
        isAccessibilityElement = true
        accessibilityLabel = accessibilityText
    }

    required init?(coder: NSCoder) {
        guard let id = coder.decodeObject(forKey: "referenceId") as? UUID else {
            return nil
        }
        self.referenceId = id
        self.accessibilityText = coder.decodeObject(forKey: "accessibilityText") as? String ?? "Referenced message"
        super.init(coder: coder)
        if let image {
            bounds = Self.makeBounds(for: image)
        }
        isAccessibilityElement = true
        accessibilityLabel = accessibilityText
    }

    override func encode(with coder: NSCoder) {
        coder.encode(referenceId, forKey: "referenceId")
        coder.encode(accessibilityText, forKey: "accessibilityText")
        super.encode(with: coder)
    }

    private static func makeBounds(for image: UIImage) -> CGRect {
        CGRect(x: 0, y: Metrics.verticalOffset, width: image.size.width, height: image.size.height)
    }

    private static func makeTokenImage(label: String) -> UIImage {
        let attributedLabel = makeTokenAttributedLabel(label: label)
        let textSize = attributedLabel.boundingRect(
            with: CGSize(width: Metrics.maxWidth - (Metrics.horizontalPadding * 2) - Metrics.iconSize - Metrics.iconSpacing, height: Metrics.height),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        ).size
        let width = min(Metrics.maxWidth, max(Metrics.minWidth, ceil(textSize.width) + (Metrics.horizontalPadding * 2) + Metrics.iconSize + Metrics.iconSpacing))
        let size = CGSize(width: width, height: Metrics.height)
        return UIGraphicsImageRenderer(size: size).image { context in
            let rect = CGRect(origin: .zero, size: size)
            UIColor.secondarySystemFill.setFill()
            UIBezierPath(roundedRect: rect, cornerRadius: 10).fill()
            if let symbol = UIImage(systemName: "arrowshape.turn.up.left")?.withConfiguration(
                UIImage.SymbolConfiguration(pointSize: Metrics.iconSize, weight: .semibold)
            ) {
                let iconRect = CGRect(
                    x: Metrics.horizontalPadding,
                    y: floor((size.height - Metrics.iconSize) / 2),
                    width: Metrics.iconSize,
                    height: Metrics.iconSize
                )
                symbol.withTintColor(.label, renderingMode: .alwaysOriginal).draw(in: iconRect)
            }
            let textRect = CGRect(
                x: Metrics.horizontalPadding + Metrics.iconSize + Metrics.iconSpacing,
                y: 6,
                width: rect.width - (Metrics.horizontalPadding * 2) - Metrics.iconSize - Metrics.iconSpacing,
                height: rect.height - 12
            )
            attributedLabel.draw(
                with: textRect,
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                context: nil
            )
            _ = context
        }
    }

    private static func makeTokenAttributedLabel(label: String) -> NSMutableAttributedString {
        let font = UIFont.clawline(.secondaryLabel, weight: .semibold)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let content = UnifiedMarkdownRenderer.makeContent(
            messageText: MessageReferenceMarkdownDisplay.renderableMarkdown(label),
            context: MarkdownMessageRenderContext(
                role: .user,
                messageID: "pending-reference-\(label)",
                metrics: ChatFlowTheme.Metrics(isCompact: true)
            ),
            baseFont: font,
            inkColor: UIColor.label,
            lineSpacing: 0,
            stripDetectedURLs: false,
            isDark: UITraitCollection.current.userInterfaceStyle == .dark
        )
        let attributedLabel = content.firstAttributedText?.mutableCopy() as? NSMutableAttributedString ?? NSMutableAttributedString(
            string: label,
            attributes: [
                .font: font,
                .foregroundColor: UIColor.label
            ]
        )
        attributedLabel.addAttribute(
            .paragraphStyle,
            value: paragraph,
            range: NSRange(location: 0, length: attributedLabel.length)
        )
        return attributedLabel
    }
}

#if DEBUG
extension MessageReferenceTextAttachment {
    static func debugRenderedTokenLabelForTests(_ label: String) -> NSAttributedString {
        makeTokenAttributedLabel(label: label)
    }
}
#endif

enum MessageReferenceMarkdownDisplay {
    static func renderableMarkdown(_ text: String) -> String {
        "\(text)\(closingMarkdownSuffix(for: text))"
    }

    private static func closingMarkdownSuffix(for text: String) -> String {
        var stack: [String] = []
        var index = text.startIndex
        while index < text.endIndex {
            if text[index...].hasPrefix("==") {
                let delimiter = String(text[index...].prefix(2))
                if stack.last == delimiter {
                    stack.removeLast()
                } else if isMarkDelimiterCandidate(in: text, at: index) || isTruncatedMarkDelimiterCandidate(in: text, at: index) {
                    stack.append(delimiter)
                }
                index = text.index(index, offsetBy: 2)
            } else if text[index...].hasPrefix("**") || text[index...].hasPrefix("__") {
                let delimiter = String(text[index...].prefix(2))
                if stack.last == delimiter {
                    stack.removeLast()
                } else {
                    stack.append(delimiter)
                }
                index = text.index(index, offsetBy: 2)
            } else if text[index] == "*" || text[index] == "_" {
                let delimiter = String(text[index])
                if stack.last == delimiter {
                    stack.removeLast()
                } else {
                    stack.append(delimiter)
                }
                index = text.index(after: index)
            } else {
                index = text.index(after: index)
            }
        }
        return stack.reversed().joined()
    }

    private static func isMarkDelimiterCandidate(in text: String, at index: String.Index) -> Bool {
        let after = text.index(index, offsetBy: 2)
        guard after < text.endIndex,
              !text[after].isWhitespace,
              text[after] != "=" else {
            return false
        }
        guard index > text.startIndex else { return true }
        let before = text.index(before: index)
        return text[before].isWhitespace || text[before].isPunctuation
    }

    private static func isTruncatedMarkDelimiterCandidate(in text: String, at index: String.Index) -> Bool {
        guard text.count >= PendingMessageReference.previewLimit || text.hasSuffix("…") else { return false }
        let after = text.index(index, offsetBy: 2)
        guard after < text.endIndex,
              !text[after].isWhitespace,
              text[after] != "=" else {
            return false
        }
        return true
    }
}
