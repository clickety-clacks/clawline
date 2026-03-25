//
//  StreamAPIClient.swift
//  Clawline
//
//  Created by Codex on 2/12/26.
//

import Foundation

struct StreamAPIError: Swift.Error, LocalizedError, Equatable {
    let code: String
    let message: String?
    let statusCode: Int

    var errorDescription: String? {
        if let message, !message.isEmpty {
            return message
        }
        return "Stream request failed (\(code))."
    }
}

final class StreamAPIClient {
    private struct ErrorEnvelope: Decodable {
        struct Payload: Decodable {
            let code: String
            let message: String
        }

        let error: Payload
    }

    private struct FetchStreamsResponse: Decodable {
        let streams: [StreamSession]
    }

    private struct FetchTrackableSessionsResponse: Decodable {
        let sessions: [TrackableSession]
    }

    private struct MutateStreamResponse: Decodable {
        let stream: StreamSession
    }

    private struct DeleteStreamResponse: Decodable {
        let deletedSessionKey: String
    }

    private struct CreateStreamRequest: Encodable {
        let idempotencyKey: String
        let displayName: String
    }

    private struct AdoptStreamRequest: Encodable {
        let sessionKey: String
    }

    private struct RenameStreamRequest: Encodable {
        let displayName: String
    }

    private struct DeleteStreamRequest: Encodable {
        let idempotencyKey: String?
    }

    private let baseURLProvider: () -> URL?
    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private static let urlPathComponentAllowed: CharacterSet = {
        CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    }()

    init(
        baseURLProvider: @escaping () -> URL?,
        session: URLSession = .shared,
        encoder: JSONEncoder = JSONEncoder(),
        decoder: JSONDecoder = JSONDecoder()
    ) {
        self.baseURLProvider = baseURLProvider
        self.session = session
        self.encoder = encoder
        self.decoder = decoder
    }

    func fetchStreams(token: String?) async throws -> [StreamSession] {
        let response: FetchStreamsResponse = try await sendRequest(
            method: "GET",
            path: "/api/streams",
            token: token,
            body: Optional<String>.none
        )
        return response.streams
    }

    func fetchTrackableSessions(token: String?) async throws -> [TrackableSession] {
        let response: FetchTrackableSessionsResponse = try await sendRequest(
            method: "GET",
            path: "/api/trackable-sessions",
            token: token,
            body: Optional<String>.none
        )
        return response.sessions
    }

    func createStream(displayName: String, idempotencyKey: String, token: String?) async throws -> StreamSession {
        let response: MutateStreamResponse = try await sendRequest(
            method: "POST",
            path: "/api/streams",
            token: token,
            body: CreateStreamRequest(idempotencyKey: idempotencyKey, displayName: displayName)
        )
        return response.stream
    }

    func adoptStream(sessionKey: String, token: String?) async throws -> StreamSession {
        let response: MutateStreamResponse = try await sendRequest(
            method: "POST",
            path: "/api/streams/adopt",
            token: token,
            body: AdoptStreamRequest(sessionKey: sessionKey)
        )
        return response.stream
    }

    func renameStream(sessionKey: String, displayName: String, token: String?) async throws -> StreamSession {
        let encodedSessionKey = encodePathComponent(sessionKey)
        let response: MutateStreamResponse = try await sendRequest(
            method: "PATCH",
            path: "/api/streams/\(encodedSessionKey)",
            token: token,
            body: RenameStreamRequest(displayName: displayName)
        )
        return response.stream
    }

    func deleteStream(sessionKey: String, idempotencyKey: String?, token: String?) async throws -> String {
        let encodedSessionKey = encodePathComponent(sessionKey)
        let response: DeleteStreamResponse = try await sendRequest(
            method: "DELETE",
            path: "/api/streams/\(encodedSessionKey)",
            token: token,
            body: DeleteStreamRequest(idempotencyKey: idempotencyKey)
        )
        return response.deletedSessionKey
    }

    private func sendRequest<Body: Encodable, Response: Decodable>(
        method: String,
        path: String,
        token: String?,
        body: Body?
    ) async throws -> Response {
        guard let baseURL = baseURLProvider() else {
            throw ProviderChatService.Error.missingBaseURL
        }
        guard let url = endpointURL(baseURL: baseURL, path: path) else {
            throw ProviderChatService.Error.missingBaseURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        if let body {
            request.httpBody = try encoder.encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProviderChatService.Error.notConnected
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            if let envelope = try? decoder.decode(ErrorEnvelope.self, from: data) {
                throw StreamAPIError(
                    code: envelope.error.code,
                    message: envelope.error.message,
                    statusCode: httpResponse.statusCode
                )
            }
            throw StreamAPIError(code: "http_\(httpResponse.statusCode)", message: nil, statusCode: httpResponse.statusCode)
        }

        return try decoder.decode(Response.self, from: data)
    }

    private func encodePathComponent(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: Self.urlPathComponentAllowed) ?? value
    }

    private func endpointURL(baseURL: URL, path: String) -> URL? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        let basePath = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        let suffix = path.hasPrefix("/") ? path : "/\(path)"
        components.path = basePath + suffix
        return components.url
    }
}
