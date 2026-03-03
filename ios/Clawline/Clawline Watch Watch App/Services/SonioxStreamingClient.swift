import AVFoundation
import Foundation

final class SonioxStreamingClient {
    enum ClientError: LocalizedError {
        case notConnected

        var errorDescription: String? {
            switch self {
            case .notConnected:
                return "Soniox socket is not connected"
            }
        }
    }

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
    }

    private let session = URLSession(configuration: .default)
    private let audioEngine = AVAudioEngine()

    private var websocketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var keepaliveTask: Task<Void, Never>?

    private var converter: AVAudioConverter?
    private var latestTranscript: String = ""
    private var finalizeContinuation: CheckedContinuation<Void, Never>?

    private var isRunning = false

    func start(apiKey: String, clientReferenceID: String = UUID().uuidString) async throws {
        guard !isRunning else { return }
        isRunning = true
        latestTranscript = ""

        do {
            let url = URL(string: "wss://stt-rt.soniox.com/transcribe-websocket")!
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            let task = session.webSocketTask(with: request)
            websocketTask = task
            task.resume()

            let config: [String: Any] = [
                "api_key": apiKey,
                "model": "stt-rt-preview",
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
