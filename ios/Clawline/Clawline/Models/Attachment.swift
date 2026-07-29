//
//  Attachment.swift
//  Clawline
//
//  Created by Codex on 1/8/26.
//

import Foundation

nonisolated struct Attachment: Identifiable, Equatable, Codable, Sendable {
    let id: String
    let type: AttachmentType
    let mimeType: String?
    let data: Data?
    let assetId: String?
    let filename: String?
    let size: Int?

    private enum CodingKeys: String, CodingKey {
        case id
        case type
        case mimeType
        case data
        case assetId
        case metadata
    }

    private struct AttachmentMetadata: Codable, Equatable, Sendable {
        let mimeType: String?
        let filename: String?
        let size: Int?
        let width: Int?
        let height: Int?
    }

    init(id: String,
         type: AttachmentType,
         mimeType: String?,
         data: Data?,
         assetId: String?,
         filename: String? = nil,
         size: Int? = nil) {
        self.id = id
        self.type = type
        self.mimeType = mimeType
        self.data = data
        self.assetId = assetId
        self.filename = filename
        self.size = size
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedType = try container.decode(AttachmentType.self, forKey: .type)
        let decodedMimeType = try container.decodeIfPresent(String.self, forKey: .mimeType)
        let metadata = try container.decodeIfPresent(AttachmentMetadata.self, forKey: .metadata)
        let decodedData = try container.decodeIfPresent(Data.self, forKey: .data)
        let decodedAssetId = try container.decodeIfPresent(String.self, forKey: .assetId)
        let decodedId = try container.decodeIfPresent(String.self, forKey: .id)

        type = decodedType
        mimeType = decodedMimeType ?? metadata?.mimeType
        data = decodedData
        assetId = decodedAssetId
        filename = metadata?.filename
        size = metadata?.size ?? decodedData?.count

        if let decodedId {
            id = decodedId
        } else if let decodedAssetId {
            id = decodedAssetId
        } else {
            id = UUID().uuidString
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(type, forKey: .type)
        try container.encodeIfPresent(mimeType, forKey: .mimeType)
        try container.encodeIfPresent(data, forKey: .data)
        try container.encodeIfPresent(assetId, forKey: .assetId)
    }
}

nonisolated enum AttachmentType: String, Codable, Equatable, Sendable {
    case image
    case asset
    case document
}
