//
//  UploadServicing.swift
//  Clawline
//
//  Created by Codex on 1/15/26.
//

import Foundation

protocol UploadServicing {
    func upload(data: Data, mimeType: String, filename: String?) async throws -> String
}

protocol AssetDownloading {
    func download(assetId: String) async throws -> Data
}
