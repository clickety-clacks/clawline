//
//  Attachment.swift
//  Clawline
//
//  Created by Codex on 1/8/26.
//

import Foundation

struct Attachment: Identifiable, Equatable, Codable {
    let id: String
    let type: AttachmentType
    let mimeType: String?
    let data: Data?
    let assetId: String?
}

enum AttachmentType: String, Codable, Equatable {
    case image
    case asset
    case document
}
