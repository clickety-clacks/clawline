//
//  SonioxKeyVerifier.swift
//  Clawline
//
//  Created by Codex on 2/14/26.
//

import Foundation

protocol SonioxKeyVerifying: AnyObject {
    func verify(apiKey: String) async -> Bool
}

final class SonioxKeyVerifier: SonioxKeyVerifying {
    private static let endpointURL = URL(string: "wss://stt-rt.soniox.com/transcribe-websocket")!
    private let session: URLSession
    private let timeout: Duration

    init(session: URLSession = URLSession(configuration: .default), timeout: Duration = .seconds(5)) {
        self.session = session
        self.timeout = timeout
    }

    func verify(apiKey: String) async -> Bool {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        var request = URLRequest(url: Self.endpointURL)
        request.timeoutInterval = 20
        request.setValue("https://clawline.app", forHTTPHeaderField: "Origin")

        let task = session.webSocketTask(with: request)
        task.resume()
        defer {
            task.cancel(with: .normalClosure, reason: nil)
        }

        do {
            let payload = SonioxKeyVerificationConfigPayload(apiKey: trimmed)
            let configData = try JSONEncoder().encode(payload)
            guard let configText = String(data: configData, encoding: .utf8) else {
                return false
            }
            try await task.send(.string(configText))

            // Trigger early auth feedback even without microphone frames.
            try await task.send(.string(#"{"type":"finalize"}"#))
            try await task.send(.data(Data()))
        } catch {
            return false
        }

        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            guard let message = await receiveMessage(task: task, timeout: .milliseconds(700)) else {
                continue
            }

            let text: String
            switch message {
            case .string(let value):
                text = value
            case .data(let data):
                guard let decoded = String(data: data, encoding: .utf8) else { continue }
                text = decoded
            @unknown default:
                continue
            }

            guard let response = try? JSONDecoder().decode(SonioxKeyVerificationResponseEnvelope.self, from: Data(text.utf8)) else {
                continue
            }

            if let errorCode = response.errorCode, !errorCode.isEmpty {
                return false
            }

            if let errorMessage = response.errorMessage, !errorMessage.isEmpty {
                return false
            }

            if response.finished == true || (response.tokens?.isEmpty == false) {
                return true
            }
        }

        return false
    }

    private func receiveMessage(
        task: URLSessionWebSocketTask,
        timeout: Duration
    ) async -> URLSessionWebSocketTask.Message? {
        await withTaskGroup(of: URLSessionWebSocketTask.Message?.self) { group in
            group.addTask {
                try? await task.receive()
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}

private struct SonioxKeyVerificationConfigPayload: Encodable {
    let apiKey: String
    let model: String = "stt-rt-preview"
    let audioFormat: String = "s16le"
    let sampleRate: Int = 16_000
    let numChannels: Int = 1
    let languageHints: [String] = ["en"]
    let enableEndpointDetection: Bool = true
    let clientReferenceID: String = UUID().uuidString

    enum CodingKeys: String, CodingKey {
        case apiKey = "api_key"
        case model
        case audioFormat = "audio_format"
        case sampleRate = "sample_rate"
        case numChannels = "num_channels"
        case languageHints = "language_hints"
        case enableEndpointDetection = "enable_endpoint_detection"
        case clientReferenceID = "client_reference_id"
    }
}

private struct SonioxKeyVerificationResponseEnvelope: Decodable {
    struct Token: Decodable {
        let text: String
    }

    let tokens: [Token]?
    let finished: Bool?
    let errorCode: String?
    let errorMessage: String?

    enum CodingKeys: String, CodingKey {
        case tokens
        case finished
        case errorCode = "error_code"
        case errorMessage = "error_message"
    }
}
