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
