//
//  Attachment.swift
//  Clawline
//
//  Created by Codex on 1/8/26.
//

import Foundation

struct Attachment: Identifiable {
    let id: String
    let type: AttachmentType
    let data: Data

    enum AttachmentType {
        case image
        case document
    }
}
