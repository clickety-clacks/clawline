//
//  WebSocketClient.swift
//  Clawline
//
//  Created by Codex on 1/12/26.
//

import Foundation

protocol WebSocketClient: AnyObject {
    var incomingTextMessages: AsyncStream<String> { get }

    func send(text: String) async throws
    func close(with code: URLSessionWebSocketTask.CloseCode?)
}

protocol WebSocketConnecting {
    func connect(to url: URL) async throws -> WebSocketClient
}
