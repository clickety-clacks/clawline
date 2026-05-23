import Foundation

struct WatchStreamAPIError: Swift.Error, LocalizedError {
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

final class WatchStreamAPIClient {
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

    private struct RenameStreamRequest: Encodable {
        let displayName: String
    }

    private struct DeleteStreamRequest: Encodable {
        let idempotencyKey: String?
    }

    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private static let urlPathComponentAllowed: CharacterSet = {
        CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    }()

    init(session: URLSession = .shared,
         encoder: JSONEncoder = JSONEncoder(),
         decoder: JSONDecoder = JSONDecoder()) {
        self.session = session
        self.encoder = encoder
        self.decoder = decoder
    }

    func fetchStreams(baseURL: URL, token: String?) async throws -> [StreamSession] {
        let response: FetchStreamsResponse = try await sendRequest(
            method: "GET",
            path: "/api/streams",
            baseURL: baseURL,
            token: token,
            body: Optional<String>.none
        )
        return response.streams
    }

    func createStream(baseURL: URL, displayName: String, idempotencyKey: String, token: String?) async throws -> StreamSession {
        let response: MutateStreamResponse = try await sendRequest(
            method: "POST",
            path: "/api/streams",
            baseURL: baseURL,
            token: token,
            body: CreateStreamRequest(idempotencyKey: idempotencyKey, displayName: displayName)
        )
        return response.stream
    }

    func renameStream(baseURL: URL, sessionKey: String, displayName: String, token: String?) async throws -> StreamSession {
        let encodedSessionKey = encodePathComponent(sessionKey)
        let response: MutateStreamResponse = try await sendRequest(
            method: "PATCH",
            path: "/api/streams/\(encodedSessionKey)",
            baseURL: baseURL,
            token: token,
            body: RenameStreamRequest(displayName: displayName)
        )
        return response.stream
    }

    func deleteStream(baseURL: URL, sessionKey: String, idempotencyKey: String?, token: String?) async throws -> String {
        let encodedSessionKey = encodePathComponent(sessionKey)
        let response: DeleteStreamResponse = try await sendRequest(
            method: "DELETE",
            path: "/api/streams/\(encodedSessionKey)",
            baseURL: baseURL,
            token: token,
            body: DeleteStreamRequest(idempotencyKey: idempotencyKey)
        )
        return response.deletedSessionKey
    }

    private func sendRequest<Body: Encodable, Response: Decodable>(
        method: String,
        path: String,
        baseURL: URL,
        token: String?,
        body: Body?
    ) async throws -> Response {
        guard let url = endpointURL(baseURL: baseURL, path: path) else {
            throw WatchStreamAPIError(code: "invalid_url", message: nil, statusCode: -1)
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
            throw WatchStreamAPIError(code: "no_response", message: nil, statusCode: -1)
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            if let envelope = try? decoder.decode(ErrorEnvelope.self, from: data) {
                throw WatchStreamAPIError(
                    code: envelope.error.code,
                    message: envelope.error.message,
                    statusCode: httpResponse.statusCode
                )
            }
            throw WatchStreamAPIError(code: "http_\(httpResponse.statusCode)", message: nil, statusCode: httpResponse.statusCode)
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
