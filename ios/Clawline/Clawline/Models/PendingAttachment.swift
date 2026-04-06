//
//  PendingAttachment.swift
//  Clawline
//
//  Created by Codex on 1/15/26.
//

import Foundation
import UIKit

struct PendingAttachment: Identifiable {
    static let inlineByteLimit: Int = 256 * 1024
    static let inlineTotalByteLimit: Int = 256 * 1024
    static let totalPayloadByteLimit: Int = 320 * 1024
    static let maxUploadByteLimit: Int = 100 * 1024 * 1024
    static let anthropicImageBase64ByteLimit: Int = 5 * 1024 * 1024
    static let modelAwareMaxImageRawByteLimit: Int = (anthropicImageBase64ByteLimit * 3) / 4
    static let inlineMimeTypes: Set<String> = [
        "image/png",
        "image/jpeg",
        "image/jpg",
        "image/gif",
        "image/webp",
        "image/heic"
    ]

    let id: UUID
    let data: Data
    let thumbnail: UIImage
    let mimeType: String
    let filename: String?

    var size: Int { data.count }

    var isInlineCapableImage: Bool {
        Self.inlineMimeTypes.contains(mimeType.lowercased())
    }

    var requiresUpload: Bool {
        !isInlineCapableImage || size > Self.inlineByteLimit
    }

    var accessibilityLabel: String {
        if isInlineCapableImage {
            return "Image attachment"
        }
        if let filename, !filename.isEmpty {
            return filename
        }
        return "Document attachment"
    }
}
