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
    case audio
}

struct SonioxStreamingConfig: Sendable {
    var apiKey: String
    var languageHint: String
    var model: String = "stt-rt-v4"
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
    func close(code: URLSessionWebSocketTask.CloseCode, reason: String?, caller: String)
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
    private enum SocketLifecycleState: String {
        case connecting
        case open
        case closing
        case closed
    }

    private static let endpointURL = URL(string: "wss://stt-rt.soniox.com/transcribe-websocket")!
    private static let keepalivePayload = #"{"type":"keepalive"}"#

    private let logger = Logger(subsystem: "co.clicketyclacks.Clawline", category: "SonioxStreamingClient")
    private let session: URLSession
    private let decoder = JSONDecoder()
    private let keepaliveInterval: Duration
    private let sleepFor: @Sendable (Duration) async -> Void

    private var socketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var keepaliveTask: Task<Void, Never>?
    private var continuation: AsyncStream<SonioxStreamingEvent>.Continuation?
    private let eventStream: AsyncStream<SonioxStreamingEvent>
    private var socketLifecycleState: SocketLifecycleState?
    private var sendSequence: UInt64 = 0
    private var receiveSequence: UInt64 = 0
    private var audioFrameSequence: UInt64 = 0

    nonisolated private static func callSite(
        function: StaticString = #function,
        fileID: StaticString = #fileID,
        line: UInt = #line
    ) -> String {
        "\(fileID):\(line) \(function)"
    }

    init(
        session: URLSession = URLSession(configuration: .default),
        keepaliveInterval: Duration = .seconds(10),
        sleepFor: @escaping @Sendable (Duration) async -> Void = { duration in
            try? await Task.sleep(for: duration)
        }
    ) {
        self.session = session
        self.keepaliveInterval = keepaliveInterval
        self.sleepFor = sleepFor
        var continuation: AsyncStream<SonioxStreamingEvent>.Continuation?
        self.eventStream = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    var events: AsyncStream<SonioxStreamingEvent> { eventStream }

    func connect(config: SonioxStreamingConfig) async throws {
        let startedAt = CFAbsoluteTimeGetCurrent()
        close(code: .goingAway, reason: "restart", caller: Self.callSite())

        var request = URLRequest(url: Self.endpointURL)
        request.timeoutInterval = 20
        if request.value(forHTTPHeaderField: "Origin") == nil {
            request.setValue("https://clawline.app", forHTTPHeaderField: "Origin")
        }

        let task = session.webSocketTask(with: request)
        logSocketStateChange(.connecting, task: task, context: "connect")
        task.resume()
        socketTask = task

        let payload = SonioxInitialConfigPayload(
            apiKey: config.apiKey,
            model: config.model,
            audioFormat: "pcm_s16le",
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
        do {
            try await task.send(.string(text))
            logSendResult(kind: "initial_config", frameBytes: data.count, success: true, error: nil)
        } catch {
            logSendResult(kind: "initial_config", frameBytes: data.count, success: false, error: error)
            continuation?.yield(.failed(stage: .send, code: nil, message: error.localizedDescription))
            throw error
        }
        logSocketStateChange(.open, task: task, context: "initial_config_sent")
        logPerfMarker(functionName: "connect", startedAt: startedAt)

        startKeepaliveLoop(task: task)
        startReceiveLoop(task: task)
    }

    func sendAudioFrame(_ frame: Data) async throws {
        let startedAt = CFAbsoluteTimeGetCurrent()
        guard let task = socketTask else {
            throw SonioxStreamingClientError.notConnected
        }
        audioFrameSequence += 1
        let audioSeq = audioFrameSequence
        do {
            try await task.send(.data(frame))
            logSendResult(kind: "audio", frameBytes: frame.count, success: true, error: nil)
            if audioSeq <= 5 {
                print("SONIOX send_audio_frame seq=\(audioSeq) bytes=\(frame.count) result=success")
            }
            logPerfMarker(functionName: "sendAudioFrame", startedAt: startedAt)
        } catch {
            logSendResult(kind: "audio", frameBytes: frame.count, success: false, error: error)
            print("SONIOX send_audio_frame seq=\(audioSeq) bytes=\(frame.count) result=error error=\(error.localizedDescription)")
            logPerfMarker(functionName: "sendAudioFrame", startedAt: startedAt)
            continuation?.yield(.failed(stage: .send, code: nil, message: error.localizedDescription))
            throw error
        }
    }

    func sendFinalize() async throws {
        guard let task = socketTask else {
            throw SonioxStreamingClientError.notConnected
        }
        stopKeepaliveLoop()
        let finalizePayload = #"{"type":"finalize"}"#
        do {
            try await task.send(.string(finalizePayload))
            logSendResult(kind: "finalize", frameBytes: finalizePayload.utf8.count, success: true, error: nil)
        } catch {
            logSendResult(kind: "finalize", frameBytes: finalizePayload.utf8.count, success: false, error: error)
            continuation?.yield(.failed(stage: .send, code: nil, message: error.localizedDescription))
            throw error
        }
    }

    func close(
        code: URLSessionWebSocketTask.CloseCode = .normalClosure,
        reason: String?,
        caller: String
    ) {
        stopKeepaliveLoop()
        receiveTask?.cancel()
        receiveTask = nil

        if let task = socketTask {
            logger.notice(
                "DICTATION_CLOSE trace_id=DICTATION_CLOSE_SOCKET_CANCEL caller=\(caller, privacy: .public) reason=\(reason ?? "nil", privacy: .public) code=\(Int(code.rawValue), privacy: .public)"
            )
            logSocketStateChange(.closing, task: task, context: "client_close_request")
            let reasonData = reason.map { Data($0.utf8) }
            task.cancel(with: code, reason: reasonData)
            logSocketStateChange(.closed, task: task, context: "client_close_cancel_sent")
            socketTask = nil
        }
    }

    private func startReceiveLoop(task: URLSessionWebSocketTask) {
        receiveTask?.cancel()
        receiveTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    let iterationStartedAt = CFAbsoluteTimeGetCurrent()
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
                    logPerfMarker(functionName: "receiveLoopIteration", startedAt: iterationStartedAt)
                } catch {
                    let rawCode = task.closeCode
                    let closeCode = rawCode == .invalid ? nil : Int(rawCode.rawValue)
                    let closeReason: String? = {
                        guard let data = task.closeReason, !data.isEmpty else { return nil }
                        return String(data: data, encoding: .utf8) ?? data.base64EncodedString()
                    }()
                    print("SONIOX receive_loop closed code=\(closeCode.map(String.init) ?? "nil") reason=\(closeReason ?? "nil") error=\(error.localizedDescription)")
                    stopKeepaliveLoop()
                    continuation?.yield(.closed(code: closeCode, reason: closeReason))
                    logSocketStateChange(.closed, task: task, context: "receive_loop_error")
                    break
                }
            }
        }
    }

    private func startKeepaliveLoop(task: URLSessionWebSocketTask) {
        stopKeepaliveLoop()
        keepaliveTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.sleepFor(self.keepaliveInterval)
                guard !Task.isCancelled else { return }
                guard self.socketTask === task else { return }
                do {
                    try await task.send(.string(Self.keepalivePayload))
                    self.logSendResult(
                        kind: "keepalive",
                        frameBytes: Self.keepalivePayload.utf8.count,
                        success: true,
                        error: nil
                    )
                } catch {
                    self.logSendResult(
                        kind: "keepalive",
                        frameBytes: Self.keepalivePayload.utf8.count,
                        success: false,
                        error: error
                    )
                    self.continuation?.yield(.failed(stage: .send, code: nil, message: error.localizedDescription))
                    return
                }
            }
        }
    }

    private func stopKeepaliveLoop() {
        keepaliveTask?.cancel()
        keepaliveTask = nil
    }

    private func handleIncomingText(_ text: String) {
        receiveSequence += 1
        let receiveSeq = receiveSequence
        logger.notice(
            "Soniox recv seq=\(receiveSeq, privacy: .public) json=\(Self.truncatedLogString(text), privacy: .public)"
        )
        do {
            let response = try decodeResponseText(text)
            if let errorCode = response.errorCode, !errorCode.isEmpty {
                logger.notice(
                    "SONIOX_ERROR_CODE code=\(errorCode, privacy: .public) message=\(response.errorMessage ?? "nil", privacy: .public)"
                )
                print("SONIOX protocol_error code=\(errorCode) message=\(response.errorMessage ?? "nil")")
            }
            continuation?.yield(.response(response))
        } catch {
            logger.notice(
                "Soniox decode_error json=\(Self.truncatedLogString(text), privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            print("SONIOX decode_error error=\(error.localizedDescription)")
            continuation?.yield(.failed(stage: .decode, code: nil, message: "Failed to decode Soniox response."))
        }
    }

    private func logSendResult(kind: String, frameBytes: Int, success: Bool, error: Error?) {
        sendSequence += 1
        let sendSeq = sendSequence
        if success {
            logger.notice(
                "Soniox send seq=\(sendSeq, privacy: .public) kind=\(kind, privacy: .public) frameBytes=\(frameBytes, privacy: .public) result=success"
            )
            return
        }
        logger.notice(
            "Soniox send seq=\(sendSeq, privacy: .public) kind=\(kind, privacy: .public) frameBytes=\(frameBytes, privacy: .public) result=error error=\(error?.localizedDescription ?? "unknown", privacy: .public)"
        )
        print("SONIOX send_error kind=\(kind) frameBytes=\(frameBytes) error=\(error?.localizedDescription ?? "unknown")")
    }

    private func logSocketStateChange(_ nextState: SocketLifecycleState, task: URLSessionWebSocketTask?, context: String) {
        if socketLifecycleState == nextState {
            return
        }
        socketLifecycleState = nextState
        let closeCode: Int = {
            guard let task else { return -1 }
            return task.closeCode == .invalid ? -1 : Int(task.closeCode.rawValue)
        }()
        let closeReason: String = {
            guard let task,
                  let reasonData = task.closeReason,
                  !reasonData.isEmpty else {
                return "nil"
            }
            return String(data: reasonData, encoding: .utf8) ?? reasonData.base64EncodedString()
        }()
        logger.notice(
            "Soniox socket_state=\(nextState.rawValue, privacy: .public) context=\(context, privacy: .public) closeCode=\(closeCode, privacy: .public) closeReason=\(closeReason, privacy: .public)"
        )
        print("SONIOX socket_state=\(nextState.rawValue) context=\(context) closeCode=\(closeCode) closeReason=\(closeReason)")
    }

    private static func truncatedLogString(_ text: String, limit: Int = 200) -> String {
        if text.count <= limit {
            return text
        }
        let end = text.index(text.startIndex, offsetBy: limit)
        return String(text[..<end]) + "…"
    }

    private func logPerfMarker(functionName: String, startedAt: CFAbsoluteTime) {
        let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1_000)
        logger.notice("[DICTATION-PERF] \(functionName, privacy: .public): \(elapsedMs, privacy: .public)ms")
    }

    func decodeResponseText(_ text: String) throws -> SonioxStreamingResponse {
        let decoded = try decoder.decode(SonioxResponseEnvelope.self, from: Data(text.utf8))
        let tokens = decoded.tokens?.map { token in
            SonioxTranscriptToken(text: token.text, isFinal: token.isFinal)
        } ?? []
        return SonioxStreamingResponse(
            tokens: tokens,
            finished: decoded.finished ?? false,
            errorCode: decoded.errorCode,
            errorMessage: decoded.errorMessage
        )
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

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tokens = try container.decodeIfPresent([Token].self, forKey: .tokens)
        finished = try container.decodeIfPresent(Bool.self, forKey: .finished)
        errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage)
        errorCode = try container.decodeIfPresent(SonioxErrorCode.self, forKey: .errorCode)?.asString
    }
}

private enum SonioxErrorCode: Decodable {
    case string(String)
    case int(Int)
    case double(Double)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .string(value)
            return
        }
        if let value = try? container.decode(Int.self) {
            self = .int(value)
            return
        }
        if let value = try? container.decode(Double.self) {
            self = .double(value)
            return
        }
        throw DecodingError.typeMismatch(
            SonioxErrorCode.self,
            .init(codingPath: decoder.codingPath, debugDescription: "Unsupported Soniox error_code type.")
        )
    }

    var asString: String {
        switch self {
        case .string(let value):
            return value
        case .int(let value):
            return String(value)
        case .double(let value):
            return String(value)
        }
    }
}
