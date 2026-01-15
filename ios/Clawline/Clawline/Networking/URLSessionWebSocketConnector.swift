//
//  URLSessionWebSocketConnector.swift
//  Clawline
//
//  Created by Codex on 1/12/26.
//

import Foundation

final class URLSessionWebSocketConnector: WebSocketConnecting {
    private let session: URLSession
    private let timeout: TimeInterval

    init(timeout: TimeInterval = 8) {
        self.timeout = timeout
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        self.session = URLSession(configuration: configuration)
    }

    func connect(to url: URL) async throws -> any WebSocketClient {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        let task = session.webSocketTask(with: request)
        task.resume()
        return URLSessionWebSocketClient(task: task)
    }
}

private final class URLSessionWebSocketClient: WebSocketClient {
    private let task: URLSessionWebSocketTask
    private let stream: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation
    private var receiveTask: Task<Void, Never>?

    init(task: URLSessionWebSocketTask) {
        self.task = task
        var continuation: AsyncStream<String>.Continuation!
        self.stream = AsyncStream { continuation = $0 }
        self.continuation = continuation
        startReceiving()
    }

    var incomingTextMessages: AsyncStream<String> { stream }

    func send(text: String) async throws {
        try await task.send(.string(text))
    }

    func close(with code: URLSessionWebSocketTask.CloseCode?) {
        task.cancel(with: code ?? .normalClosure, reason: nil)
        receiveTask?.cancel()
        continuation.finish()
    }

    private func startReceiving() {
        receiveTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    let message = try await task.receive()
                    switch message {
                    case .string(let text):
                        continuation.yield(text)
                    case .data(let data):
                        if let text = String(data: data, encoding: .utf8) {
                            continuation.yield(text)
                        }
                    @unknown default:
                        break
                    }
                } catch {
                    continuation.finish()
                    break
                }
            }
        }
    }
}
