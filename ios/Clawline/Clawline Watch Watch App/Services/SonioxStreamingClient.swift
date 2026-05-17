import AVFoundation
import Foundation

protocol WatchVoiceStreaming: AnyObject {
    var onTranscriptUpdate: ((SonioxStreamingClient.TranscriptUpdate) -> Void)? { get set }
    var onAudioLevel: ((Float) -> Void)? { get set }
    var onError: ((Error) -> Void)? { get set }

    func start(apiKey: String, clientReferenceID: String) async throws
    func finalize(timeoutNanoseconds: UInt64) async -> String
    func stop()
}

extension WatchVoiceStreaming {
    func start(apiKey: String) async throws {
        try await start(apiKey: apiKey, clientReferenceID: UUID().uuidString)
    }

    func finalize() async -> String {
        await finalize(timeoutNanoseconds: 1_200_000_000)
    }
}

final class SonioxStreamingClient: WatchVoiceStreaming {
    static let model = "stt-rt-v4"

    enum ClientError: LocalizedError {
        case notConnected
        case serverError(code: String?, message: String?)

        var errorDescription: String? {
            switch self {
            case .notConnected:
                return "Soniox socket is not connected"
            case .serverError(let code, let message):
                let trimmedMessage = message?.trimmingCharacters(in: .whitespacesAndNewlines)
                let trimmedCode = code?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let trimmedMessage, !trimmedMessage.isEmpty,
                   let trimmedCode, !trimmedCode.isEmpty {
                    return "Soniox error \(trimmedCode): \(trimmedMessage)"
                }
                if let trimmedMessage, !trimmedMessage.isEmpty {
                    return "Soniox error: \(trimmedMessage)"
                }
                if let trimmedCode, !trimmedCode.isEmpty {
                    return "Soniox error \(trimmedCode)"
                }
                return "Soniox returned an error"
            }
        }
    }

    private static let endpointURL = URL(string: "wss://stt-rt.soniox.com/transcribe-websocket")!
    private static let originHeaderValue = "https://clawline.app"

    struct TranscriptUpdate {
        let text: String
        let isFinal: Bool
        let finished: Bool
    }

    var onTranscriptUpdate: ((TranscriptUpdate) -> Void)?
    var onAudioLevel: ((Float) -> Void)?
    var onError: ((Error) -> Void)?

    private struct SonioxResponse: Decodable {
        struct Token: Decodable {
            let text: String
            let isFinal: Bool?

            enum CodingKeys: String, CodingKey {
                case text
                case isFinal = "is_final"
            }
        }

        let text: String?
        let tokens: [Token]?
        let finished: Bool?
        let rawErrorCode: SonioxErrorCode?
        let errorMessage: String?

        enum CodingKeys: String, CodingKey {
            case text
            case tokens
            case finished
            case rawErrorCode = "error_code"
            case errorMessage = "error_message"
        }

        var errorCode: String? {
            rawErrorCode?.asString
        }

        var hasError: Bool {
            errorCode?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ||
                errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
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

    private let session: URLSession
    private let audioEngine = AVAudioEngine()

    private var websocketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var keepaliveTask: Task<Void, Never>?

    private var converter: AVAudioConverter?
    private var latestTranscript: String = ""
    private var finalizeContinuation: CheckedContinuation<Void, Never>?

    private var isRunning = false

    init(session: URLSession = URLSession(configuration: SonioxStreamingClient.watchSessionConfiguration())) {
        self.session = session
    }

    static func watchSessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = true
        configuration.allowsCellularAccess = true
        configuration.allowsExpensiveNetworkAccess = true
        configuration.allowsConstrainedNetworkAccess = true
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 75
        return configuration
    }

    static func webSocketRequest() -> URLRequest {
        var request = URLRequest(url: endpointURL)
        request.timeoutInterval = 30
        request.setValue(originHeaderValue, forHTTPHeaderField: "Origin")
        return request
    }

    static func decodeServerError(from text: String) -> ClientError? {
        guard let data = text.data(using: .utf8),
              let payload = try? JSONDecoder().decode(SonioxResponse.self, from: data),
              payload.hasError else {
            return nil
        }
        return .serverError(code: payload.errorCode, message: payload.errorMessage)
    }

    func start(apiKey: String, clientReferenceID: String = UUID().uuidString) async throws {
        guard !isRunning else { return }
        isRunning = true
        latestTranscript = ""

        do {
            let request = Self.webSocketRequest()
            let task = session.webSocketTask(with: request)
            websocketTask = task
            task.resume()

            let config: [String: Any] = [
                "api_key": apiKey,
                "model": Self.model,
                "audio_format": "s16le",
                "sample_rate": 16000,
                "num_channels": 1,
                "language_hints": ["en"],
                "enable_endpoint_detection": true,
                "client_reference_id": clientReferenceID
            ]
            try await sendJSON(config)

            startReceiveLoop()
            startKeepaliveLoop()
            try startAudioCapture()
        } catch {
            stop()
            throw error
        }
    }

    func finalize(timeoutNanoseconds: UInt64 = 1_200_000_000) async -> String {
        guard isRunning else { return latestTranscript }

        stopAudioCapture()

        do {
            try await sendJSON(["type": "finalize"])
            try await websocketTask?.send(.data(Data()))
        } catch {
            onError?(error)
        }

        await withTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                guard let self else { return }
                await self.waitForFinalizeSignal()
            }

            group.addTask {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
            }

            _ = await group.next()
            group.cancelAll()
        }

        stop()
        return latestTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false

        stopAudioCapture()
        keepaliveTask?.cancel()
        keepaliveTask = nil
        receiveTask?.cancel()
        receiveTask = nil

        websocketTask?.cancel(with: .normalClosure, reason: nil)
        websocketTask = nil

        finalizeContinuation?.resume()
        finalizeContinuation = nil
    }

    private func startReceiveLoop() {
        guard let websocketTask else { return }

        receiveTask?.cancel()
        receiveTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    let message = try await websocketTask.receive()
                    switch message {
                    case .string(let string):
                        handleIncomingText(string)
                    case .data(let data):
                        if let string = String(data: data, encoding: .utf8) {
                            handleIncomingText(string)
                        }
                    @unknown default:
                        break
                    }
                } catch {
                    onError?(error)
                    stop()
                    break
                }
            }
        }
    }

    private func waitForFinalizeSignal() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            finalizeContinuation = continuation
        }
    }

    private func startKeepaliveLoop() {
        keepaliveTask?.cancel()
        keepaliveTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled else { break }
                try? await sendJSON(["type": "keepalive"])
            }
        }
    }

    private func handleIncomingText(_ text: String) {
        guard let data = text.data(using: .utf8),
              let payload = try? JSONDecoder().decode(SonioxResponse.self, from: data) else {
            return
        }

        if let error = Self.decodeServerError(from: text) {
            onError?(error)
            stop()
            return
        }

        let transcript: String = {
            if let text = payload.text {
                return text
            }
            if let tokens = payload.tokens {
                return tokens.map(\.text).joined()
            }
            return latestTranscript
        }()

        let isFinal = payload.tokens?.allSatisfy { $0.isFinal == true } ?? false
        latestTranscript = transcript

        onTranscriptUpdate?(
            TranscriptUpdate(
                text: transcript,
                isFinal: isFinal,
                finished: payload.finished == true
            )
        )

        if payload.finished == true {
            finalizeContinuation?.resume()
            finalizeContinuation = nil
        }
    }

    private func sendJSON(_ object: [String: Any]) async throws {
        guard let websocketTask else {
            throw ClientError.notConnected
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [])
        guard let text = String(data: data, encoding: .utf8) else { return }
        try await websocketTask.send(.string(text))
    }

    private func startAudioCapture() throws {
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)

        guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                               sampleRate: 16000,
                                               channels: 1,
                                               interleaved: true) else {
            throw NSError(domain: "SonioxStreamingClient", code: -1)
        }

        converter = AVAudioConverter(from: inputFormat, to: targetFormat)

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.handleInputBuffer(buffer, targetFormat: targetFormat)
        }

        audioEngine.prepare()
        try audioEngine.start()
    }

    private func stopAudioCapture() {
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
    }

    private func handleInputBuffer(_ buffer: AVAudioPCMBuffer, targetFormat: AVAudioFormat) {
        guard let converter else { return }

        if let floatData = buffer.floatChannelData {
            let channel = floatData[0]
            let frameCount = Int(buffer.frameLength)
            var sum: Float = 0
            if frameCount > 0 {
                for i in 0..<frameCount {
                    let sample = channel[i]
                    sum += sample * sample
                }
                let rms = sqrt(sum / Float(frameCount))
                onAudioLevel?(rms)
            }
        }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let targetFrames = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1)
        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: targetFrames) else {
            return
        }

        var sourceBufferConsumed = false
        var conversionError: NSError?
        let status = converter.convert(to: convertedBuffer, error: &conversionError) { _, outStatus in
            if sourceBufferConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            sourceBufferConsumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        guard status != .error,
              conversionError == nil,
              convertedBuffer.frameLength > 0,
              let channelData = convertedBuffer.int16ChannelData else {
            return
        }

        let sampleCount = Int(convertedBuffer.frameLength)
        let byteCount = sampleCount * MemoryLayout<Int16>.size
        let data = Data(bytes: channelData[0], count: byteCount)

        Task { [weak self] in
            guard let self else { return }
            guard let websocketTask = self.websocketTask else {
                self.onError?(ClientError.notConnected)
                return
            }
            do {
                try await websocketTask.send(.data(data))
            } catch {
                self.onError?(error)
            }
        }
    }
}
