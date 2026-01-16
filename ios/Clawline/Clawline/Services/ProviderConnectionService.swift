//
//  ProviderConnectionService.swift
//  Clawline
//
//  Created by Codex on 1/12/26.
//

import Foundation
import OSLog
#if canImport(UIKit)
import UIKit
#endif

final class ProviderConnectionService: ConnectionServicing {
    private let logger = Logger(subsystem: "co.clicketyclacks.Clawline", category: "ProviderConnectionService")
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
    private let operationTimeout: Duration
    private let pendingTimeout: Duration

    init(connector: any WebSocketConnecting,
         encoder: JSONEncoder = JSONEncoder(),
         decoder: JSONDecoder = JSONDecoder(),
         connectionTimeout: Duration = .seconds(20),
         pendingTimeout: Duration = .seconds(300)) {
        self.connector = connector
        self.encoder = encoder
        self.decoder = decoder
        self.operationTimeout = connectionTimeout
        self.pendingTimeout = pendingTimeout
    }

    func requestPairing(serverURL: URL, claimedName: String, deviceId: String) async throws -> PairingResult {
        logger.debug("requestPairing invoked (url: \(serverURL.absoluteString, privacy: .public), claimedName: \(claimedName, privacy: .public))")
        guard serverURL.scheme?.hasPrefix("ws") == true else {
            throw Error.unsupportedURL
        }

        let socket = try await runWithTimeout(timeout: operationTimeout) { [self] in
            try await connector.connect(to: serverURL)
        }
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

        try await runWithTimeout(timeout: operationTimeout) {
            try await socket.send(text: json)
        }

        while true {
            let text = try await waitForMessage(stream: socket.incomingTextMessages)
            let response = try decoder.decode(PairResultPayload.self, from: Data(text.utf8))

            guard response.type == "pair_result" else {
                logger.warning("Ignoring unexpected payload type \(response.type, privacy: .public)")
                continue
            }

            if response.reason == "pair_pending" {
                logger.debug("Pairing still pending approval...")
                continue
            }

            if response.success,
               let token = response.token,
               let userId = response.userId {
                return .success(token: token, userId: userId)
            }

            let reason = response.reason ?? "Pairing request denied"
            return .denied(reason: reason)
        }
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

            group.addTask { [pendingTimeout] in
                try await Task.sleep(for: pendingTimeout)
                throw Error.timeout
            }

            guard let value = try await group.next() else {
                throw Error.invalidResponse
            }
            group.cancelAll()
            return value
        }
    }

    private func runWithTimeout<T>(timeout: Duration, _ operation: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }

            group.addTask {
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
