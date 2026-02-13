//
//  SonioxStreamingClient.swift
//  Clawline
//
//  Created by Codex on 2/13/26.
//

import Foundation
import OSLog

enum SonioxStreamingClientStage: String, Sendable {
    case connect
    case receive
    case send
    case decode
}

struct SonioxStreamingConfig: Sendable {
    var apiKey: String
    var languageHint: String
    var model: String = "stt-rt-preview"
    var sampleRate: Int = 16_000
    var channels: Int = 1
    var clientReferenceID: String = UUID().uuidString
}

struct SonioxStreamingResponse: Sendable {
    let tokens: [SonioxTranscriptToken]
    let finished: Bool
    let errorCode: String?
    let errorMessage: String?
}

enum SonioxStreamingEvent: Sendable {
    case response(SonioxStreamingResponse)
    case closed(code: Int?, reason: String?)
    case failed(stage: SonioxStreamingClientStage, code: String?, message: String)
}

protocol SonioxStreamingClienting: AnyObject {
    var events: AsyncStream<SonioxStreamingEvent> { get }

    func connect(config: SonioxStreamingConfig) async throws
    func sendAudioFrame(_ frame: Data) async throws
    func sendFinalize() async throws
    func close(code: URLSessionWebSocketTask.CloseCode, reason: String?)
}

enum SonioxStreamingClientError: LocalizedError {
    case notConnected
    case invalidConfigEncoding

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Soniox socket is not connected."
        case .invalidConfigEncoding:
            return "Failed to encode Soniox config payload."
        }
    }
}

final class SonioxStreamingClient: SonioxStreamingClienting {
    private static let endpointURL = URL(string: "wss://stt-rt.soniox.com/transcribe-websocket")!

    private let logger = Logger(subsystem: "co.clicketyclacks.Clawline", category: "SonioxStreamingClient")
    private let session: URLSession
    private let decoder = JSONDecoder()

    private var socketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var continuation: AsyncStream<SonioxStreamingEvent>.Continuation?
    private let eventStream: AsyncStream<SonioxStreamingEvent>

    init(session: URLSession = URLSession(configuration: .default)) {
        self.session = session
        var continuation: AsyncStream<SonioxStreamingEvent>.Continuation?
        self.eventStream = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    var events: AsyncStream<SonioxStreamingEvent> { eventStream }

    func connect(config: SonioxStreamingConfig) async throws {
        close(code: .goingAway, reason: "restart")

        var request = URLRequest(url: Self.endpointURL)
        request.timeoutInterval = 20
        if request.value(forHTTPHeaderField: "Origin") == nil {
            request.setValue("https://clawline.app", forHTTPHeaderField: "Origin")
        }

        let task = session.webSocketTask(with: request)
        task.resume()
        socketTask = task

        let payload = SonioxInitialConfigPayload(
            apiKey: config.apiKey,
            model: config.model,
            audioFormat: "s16le",
            sampleRate: config.sampleRate,
            numChannels: config.channels,
            languageHints: [config.languageHint],
            enableEndpointDetection: true,
            clientReferenceID: config.clientReferenceID
        )

        let data = try JSONEncoder().encode(payload)
        guard let text = String(data: data, encoding: .utf8) else {
            throw SonioxStreamingClientError.invalidConfigEncoding
        }
        try await task.send(.string(text))

        startReceiveLoop(task: task)
    }

    func sendAudioFrame(_ frame: Data) async throws {
        guard let task = socketTask else {
            throw SonioxStreamingClientError.notConnected
        }
        do {
            try await task.send(.data(frame))
        } catch {
            continuation?.yield(.failed(stage: .send, code: nil, message: error.localizedDescription))
            throw error
        }
    }

    func sendFinalize() async throws {
        guard let task = socketTask else {
            throw SonioxStreamingClientError.notConnected
        }
        do {
            try await task.send(.string(#"{"type":"finalize"}"#))
        } catch {
            continuation?.yield(.failed(stage: .send, code: nil, message: error.localizedDescription))
            throw error
        }
    }

    func close(code: URLSessionWebSocketTask.CloseCode = .normalClosure, reason: String?) {
        receiveTask?.cancel()
        receiveTask = nil

        if let task = socketTask {
            let reasonData = reason.map { Data($0.utf8) }
            task.cancel(with: code, reason: reasonData)
            socketTask = nil
        }
    }

    private func startReceiveLoop(task: URLSessionWebSocketTask) {
        receiveTask?.cancel()
        receiveTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    let message = try await task.receive()
                    switch message {
                    case .string(let text):
                        handleIncomingText(text)
                    case .data(let data):
                        if let text = String(data: data, encoding: .utf8) {
                            handleIncomingText(text)
                        } else {
                            continuation?.yield(.failed(stage: .decode, code: nil, message: "Received non-UTF8 payload."))
                        }
                    @unknown default:
                        continue
                    }
                } catch {
                    let rawCode = task.closeCode
                    let closeCode = rawCode == .invalid ? nil : Int(rawCode.rawValue)
                    let closeReason: String? = {
                        guard let data = task.closeReason, !data.isEmpty else { return nil }
                        return String(data: data, encoding: .utf8) ?? data.base64EncodedString()
                    }()
                    continuation?.yield(.closed(code: closeCode, reason: closeReason))
                    logger.info("Soniox socket closed code=\(closeCode ?? -1, privacy: .public)")
                    break
                }
            }
        }
    }

    private func handleIncomingText(_ text: String) {
        do {
            let decoded = try decoder.decode(SonioxResponseEnvelope.self, from: Data(text.utf8))
            let tokens = decoded.tokens?.map { token in
                SonioxTranscriptToken(text: token.text, isFinal: token.isFinal)
            } ?? []
            let response = SonioxStreamingResponse(
                tokens: tokens,
                finished: decoded.finished ?? false,
                errorCode: decoded.errorCode,
                errorMessage: decoded.errorMessage
            )
            continuation?.yield(.response(response))
        } catch {
            continuation?.yield(.failed(stage: .decode, code: nil, message: "Failed to decode Soniox response."))
        }
    }
}

private struct SonioxInitialConfigPayload: Encodable {
    let apiKey: String
    let model: String
    let audioFormat: String
    let sampleRate: Int
    let numChannels: Int
    let languageHints: [String]
    let enableEndpointDetection: Bool
    let clientReferenceID: String

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

private struct SonioxResponseEnvelope: Decodable {
    let tokens: [Token]?
    let finished: Bool?
    let errorCode: String?
    let errorMessage: String?

    struct Token: Decodable {
        let text: String
        let isFinal: Bool

        enum CodingKeys: String, CodingKey {
            case text
            case isFinal = "is_final"
        }
    }

    enum CodingKeys: String, CodingKey {
        case tokens
        case finished
        case errorCode = "error_code"
        case errorMessage = "error_message"
    }
}
