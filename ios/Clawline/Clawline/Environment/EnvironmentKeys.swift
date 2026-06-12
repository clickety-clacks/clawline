//
//  EnvironmentKeys.swift
//  Clawline
//
//  Created by Codex on 1/8/26.
//

import SwiftUI

private struct ConnectionServiceKey: EnvironmentKey {
    static let defaultValue: any ConnectionServicing = StubConnectionService()
}

extension EnvironmentValues {
    var connectionService: any ConnectionServicing {
        get { self[ConnectionServiceKey.self] }
        set { self[ConnectionServiceKey.self] = newValue }
    }
}

private struct DeviceIdentifierKey: EnvironmentKey {
    static let defaultValue: any DeviceIdentifying = DeviceIdentifier()
}

extension EnvironmentValues {
    var deviceIdentifier: any DeviceIdentifying {
        get { self[DeviceIdentifierKey.self] }
        set { self[DeviceIdentifierKey.self] = newValue }
    }
}

private struct ChatServiceKey: EnvironmentKey {
    static let defaultValue: any ChatServicing = StubChatService()
}

extension EnvironmentValues {
    var chatService: any ChatServicing {
        get { self[ChatServiceKey.self] }
        set { self[ChatServiceKey.self] = newValue }
    }
}

private struct UploadServiceKey: EnvironmentKey {
    static let defaultValue: any UploadServicing = StubUploadService()
}

extension EnvironmentValues {
    var uploadService: any UploadServicing {
        get { self[UploadServiceKey.self] }
        set { self[UploadServiceKey.self] = newValue }
    }
}

private struct AllowsTransparentWindowBackgroundKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var allowsTransparentWindowBackground: Bool {
        get { self[AllowsTransparentWindowBackgroundKey.self] }
        set { self[AllowsTransparentWindowBackgroundKey.self] = newValue }
    }
}

private struct StubUploadService: UploadServicing {
    func upload(data: Data, mimeType: String, filename: String?) async throws -> String {
        throw AttachmentError.missingAuth
    }

    func download(assetId: String) async throws -> Data {
        throw AttachmentError.missingAuth
    }
}
