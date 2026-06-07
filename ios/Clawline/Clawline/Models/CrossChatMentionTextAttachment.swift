//
//  CrossChatMentionTextAttachment.swift
//  Clawline
//

import UIKit

final class CrossChatMentionTextAttachment: NSTextAttachment {
    private enum Metrics {
        static let horizontalPadding: CGFloat = 10
        static let iconGap: CGFloat = 6
        static let maxWidth: CGFloat = 260
        static let height: CGFloat = 30
        static let verticalOffset: CGFloat = -7
    }

    let destinationChatId: String
    let displayName: String

    init(destinationChatId: String, displayName: String) {
        self.destinationChatId = destinationChatId
        self.displayName = displayName
        super.init(data: nil, ofType: nil)
        image = Self.makeImage(displayName: displayName)
        bounds = CGRect(
            x: 0,
            y: Metrics.verticalOffset,
            width: image?.size.width ?? Metrics.maxWidth,
            height: Metrics.height
        )
        isAccessibilityElement = true
        accessibilityLabel = "Mention \(displayName)"
    }

    required init?(coder: NSCoder) {
        guard let destinationChatId = coder.decodeObject(forKey: "destinationChatId") as? String,
              let displayName = coder.decodeObject(forKey: "displayName") as? String else {
            return nil
        }
        self.destinationChatId = destinationChatId
        self.displayName = displayName
        super.init(coder: coder)
        image = Self.makeImage(displayName: displayName)
        bounds = CGRect(
            x: 0,
            y: Metrics.verticalOffset,
            width: image?.size.width ?? Metrics.maxWidth,
            height: Metrics.height
        )
        isAccessibilityElement = true
        accessibilityLabel = "Mention \(displayName)"
    }

    override func encode(with coder: NSCoder) {
        coder.encode(destinationChatId, forKey: "destinationChatId")
        coder.encode(displayName, forKey: "displayName")
        super.encode(with: coder)
    }

    private static func makeImage(displayName: String) -> UIImage {
        let font = UIFont.clawline(.secondaryLabel).withWeight(.semibold)
        let iconConfiguration = UIImage.SymbolConfiguration(pointSize: font.pointSize, weight: .semibold)
        let iconImage = UIImage(systemName: "bubble.left.and.bubble.right", withConfiguration: iconConfiguration)?
            .withTintColor(.secondaryLabel, renderingMode: .alwaysOriginal)
        let title = displayName as NSString
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.label,
            .paragraphStyle: paragraph
        ]
        let iconSize = iconImage?.size ?? CGSize(width: font.pointSize, height: font.pointSize)
        let titleSize = title.size(withAttributes: titleAttributes)
        let rawWidth = Metrics.horizontalPadding * 2 + iconSize.width + Metrics.iconGap + titleSize.width
        let width = min(Metrics.maxWidth, ceil(rawWidth))
        let size = CGSize(width: width, height: Metrics.height)

        let renderer = UIGraphicsImageRenderer(size: size, format: {
            let format = UIGraphicsImageRendererFormat()
            return format
        }())
        return renderer.image { context in
            let rect = CGRect(origin: .zero, size: size)
            let path = UIBezierPath(roundedRect: rect, cornerRadius: Metrics.height / 2)
            UIColor.label.withAlphaComponent(0.10).setFill()
            path.fill()

            let iconOrigin = CGPoint(
                x: Metrics.horizontalPadding,
                y: floor((Metrics.height - iconSize.height) / 2)
            )
            iconImage?.draw(in: CGRect(origin: iconOrigin, size: iconSize))

            context.cgContext.saveGState()
            let titleAvailableWidth = max(
                1,
                width - Metrics.horizontalPadding * 2 - iconSize.width - Metrics.iconGap
            )
            let titleRect = CGRect(
                x: Metrics.horizontalPadding + iconSize.width + Metrics.iconGap,
                y: floor((Metrics.height - titleSize.height) / 2),
                width: titleAvailableWidth,
                height: titleSize.height
            )
            title.draw(
                with: titleRect,
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                attributes: titleAttributes,
                context: nil
            )
            context.cgContext.restoreGState()
        }
    }
}

extension UIFont {
    fileprivate func withWeight(_ weight: UIFont.Weight) -> UIFont {
        UIFont.systemFont(ofSize: pointSize, weight: weight)
    }
}

extension NSAttributedString {
    var containsCrossChatMentionAttachment: Bool {
        var found = false
        enumerateAttribute(.attachment, in: NSRange(location: 0, length: length)) { value, _, stop in
            if value is CrossChatMentionTextAttachment {
                found = true
                stop.pointee = true
            }
        }
        return found
    }

    func contentAfterCrossChatMentionAttachment() -> NSAttributedString? {
        var mentionRange: NSRange?
        enumerateAttribute(.attachment, in: NSRange(location: 0, length: length)) { value, range, stop in
            if value is CrossChatMentionTextAttachment {
                mentionRange = range
                stop.pointee = true
            }
        }
        guard let mentionRange else { return nil }
        let start = mentionRange.upperBound
        guard start <= length else { return NSAttributedString() }
        return attributedSubstring(from: NSRange(location: start, length: length - start))
    }
}

extension NSMutableAttributedString {
    func removeCrossChatMentionAttachments() {
        enumerateAttribute(.attachment, in: NSRange(location: 0, length: length), options: .reverse) { value, range, _ in
            guard value is CrossChatMentionTextAttachment else { return }
            deleteCharacters(in: range)
        }
    }
}
