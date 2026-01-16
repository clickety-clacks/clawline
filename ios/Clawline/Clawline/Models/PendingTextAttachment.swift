//
//  PendingTextAttachment.swift
//  Clawline
//
//  Created by Codex on 1/15/26.
//

import UIKit

final class PendingTextAttachment: NSTextAttachment {
    private enum Metrics {
        static let targetHeight: CGFloat = 44
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
        let aspect = image.size.height == 0 ? 1 : image.size.width / image.size.height
        let height = Metrics.targetHeight
        let width = min(max(height * aspect, height * 0.6), Metrics.maxWidth)
        return CGRect(x: 0, y: Metrics.verticalOffset, width: width, height: height)
    }
}
