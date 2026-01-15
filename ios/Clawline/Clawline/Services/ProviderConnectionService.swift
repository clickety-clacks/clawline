//
//  ProviderConnectionService.swift
//  Clawline
//
//  Created by Codex on 1/12/26.
//

import Foundation
#if canImport(UIKit)
import UIKit
#endif

final class ProviderConnectionService: ConnectionServicing {
    private struct PairRequestPayload: Encodable {
        let type = "pair_request"
        let protocolVersion = 1
        let deviceId: String
        let claimedName: String
        let deviceInfo: DeviceInfoPayload
    }

    private struct DeviceInfoPayload: Encodable {
        let platform: String
        let model: String
    }

    private struct PairResultPayload: Decodable {
        let type: String
        let success: Bool
        let token: String?
        let userId: String?
        let reason: String?
    }

    enum Error: Swift.Error, LocalizedError {
        case timeout
        case socketClosed
        case invalidResponse
        case unsupportedURL

        var errorDescription: String? {
            switch self {
            case .timeout:
                return "Pairing timed out. Please try again."
            case .socketClosed:
                return "Connection closed by server."
            case .invalidResponse:
                return "Received unexpected response from provider."
            case .unsupportedURL:
                return "Unsupported server configuration."
            }
        }
    }

    private let connector: any WebSocketConnecting
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let timeout: Duration

    init(connector: any WebSocketConnecting,
         encoder: JSONEncoder = JSONEncoder(),
         decoder: JSONDecoder = JSONDecoder(),
         timeout: Duration = .seconds(20)) {
        self.connector = connector
        self.encoder = encoder
        self.decoder = decoder
        self.timeout = timeout
    }

    func requestPairing(serverURL: URL, claimedName: String, deviceId: String) async throws -> PairingResult {
        guard serverURL.scheme?.hasPrefix("ws") == true else {
            throw Error.unsupportedURL
        }

        let socket = try await connector.connect(to: serverURL)
        defer { socket.close(with: .normalClosure) }

        let trimmedName = String(claimedName.prefix(64))
        let payload = PairRequestPayload(
            deviceId: deviceId,
            claimedName: trimmedName,
            deviceInfo: makeDeviceInfo()
        )

        let data = try encoder.encode(payload)
        guard let json = String(data: data, encoding: .utf8) else {
            throw Error.invalidResponse
        }

        try await socket.send(text: json)

        let text = try await waitForMessage(stream: socket.incomingTextMessages)
        let response = try decoder.decode(PairResultPayload.self, from: Data(text.utf8))

        guard response.type == "pair_result" else {
            throw Error.invalidResponse
        }

        if response.success,
           let token = response.token,
           let userId = response.userId {
            return .success(token: token, userId: userId)
        }

        let reason = response.reason ?? "Pairing request denied"
        return .denied(reason: reason)
    }

    private func waitForMessage(stream: AsyncStream<String>) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                guard let text = await iterator.next() else {
                    throw Error.socketClosed
                }
                return text
            }

            group.addTask { [timeout] in
                try await Task.sleep(for: timeout)
                throw Error.timeout
            }

            guard let value = try await group.next() else {
                throw Error.invalidResponse
            }
            group.cancelAll()
            return value
        }
    }

    private func makeDeviceInfo() -> DeviceInfoPayload {
#if canImport(UIKit)
        let device = UIDevice.current
        return DeviceInfoPayload(platform: "iOS", model: device.model)
#else
        return DeviceInfoPayload(platform: "iOS", model: "Simulator")
#endif
    }
}
