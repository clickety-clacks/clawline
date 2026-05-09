import Foundation

final class CartesiaTTSClient {
    enum ClientError: LocalizedError {
        case notConnected

        var errorDescription: String? {
            switch self {
            case .notConnected:
                return "Cartesia socket is not connected"
            }
        }
    }

    struct Handler {
        let onChunk: (Data) -> Void
        let onAudioLevel: (Float) -> Void
        let onDone: () -> Void
        let onError: (Error) -> Void
    }

    private struct ChunkResponse: Decodable {
        let type: String?
        let data: String?
        let done: Bool?
        let contextId: String?
        let error: String?

        enum CodingKeys: String, CodingKey {
            case type
            case data
            case done
            case contextId = "context_id"
            case error
        }
    }

    private let session = URLSession(configuration: .default)
    private var websocketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var handlers: [String: Handler] = [:]
    private var apiKey: String?

    func speak(
        text: String,
        apiKey: String,
        voiceId: String,
        contextId: String = UUID().uuidString,
        onChunk: @escaping (Data) -> Void,
        onAudioLevel: @escaping (Float) -> Void,
        onDone: @escaping () -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> String {
        try await ensureConnected(apiKey: apiKey)

        handlers[contextId] = Handler(
            onChunk: onChunk,
            onAudioLevel: onAudioLevel,
            onDone: onDone,
            onError: onError
        )

        let payload: [String: Any] = [
            "model_id": "sonic-3",
            "transcript": text,
            "voice": [
                "mode": "id",
                "id": voiceId
            ],
            "language": "en",
            "context_id": contextId,
            "output_format": [
                "container": "raw",
                "encoding": "pcm_s16le",
                "sample_rate": 24000
            ],
            "continue": false
        ]

        do {
            try await sendJSON(payload)
        } catch {
            handlers.removeValue(forKey: contextId)
            throw error
        }
        return contextId
    }

    func cancel(contextId: String) async {
        guard websocketTask != nil else { return }
        try? await sendJSON([
            "context_id": contextId,
            "cancel": true
        ])
        handlers.removeValue(forKey: contextId)
    }

    func close() {
        receiveTask?.cancel()
        receiveTask = nil

        websocketTask?.cancel(with: .normalClosure, reason: nil)
        websocketTask = nil

        handlers.removeAll()
        apiKey = nil
    }

    private func ensureConnected(apiKey: String) async throws {
        if websocketTask != nil, self.apiKey == apiKey {
            return
        }

        close()

        var components = URLComponents(string: "wss://api.cartesia.ai/tts/websocket")!
        components.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "cartesia_version", value: "2025-04-16")
        ]

        guard let url = components.url else {
            throw URLError(.badURL)
        }

        let task = session.webSocketTask(with: url)
        websocketTask = task
        self.apiKey = apiKey
        task.resume()
        startReceiveLoop(task: task)
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
                        handle(text: text)
                    case .data(let data):
                        if let text = String(data: data, encoding: .utf8) {
                            handle(text: text)
                        }
                    @unknown default:
                        break
                    }
                } catch {
                    let activeHandlers = handlers.values
                    handlers.removeAll()
                    activeHandlers.forEach { $0.onError(error) }
                    websocketTask = nil
                    break
                }
            }
        }
    }

    private func handle(text: String) {
        guard let data = text.data(using: .utf8),
              let payload = try? JSONDecoder().decode(ChunkResponse.self, from: data),
              let contextId = payload.contextId,
              let handler = handlers[contextId] else {
            return
        }

        if let chunk = payload.data,
           let pcm = Data(base64Encoded: chunk) {
            handler.onChunk(pcm)

            let level = rms(fromPCM16LE: pcm)
            handler.onAudioLevel(level)
        }

        if payload.done == true {
            handlers.removeValue(forKey: contextId)
            handler.onDone()
            return
        }

        if let error = payload.error {
            handlers.removeValue(forKey: contextId)
            handler.onError(NSError(domain: "Cartesia", code: -1, userInfo: [NSLocalizedDescriptionKey: error]))
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

    private func rms(fromPCM16LE data: Data) -> Float {
        if data.isEmpty { return 0 }
        let sampleCount = data.count / MemoryLayout<Int16>.size
        if sampleCount == 0 { return 0 }

        var sum: Float = 0
        data.withUnsafeBytes { rawBuffer in
            guard let pointer = rawBuffer.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }
            for index in 0..<sampleCount {
                let sample = Float(pointer[index]) / Float(Int16.max)
                sum += sample * sample
            }
        }
        return sqrt(sum / Float(sampleCount))
    }
}
