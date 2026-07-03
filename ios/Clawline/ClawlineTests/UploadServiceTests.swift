//
//  UploadServiceTests.swift
//  ClawlineTests
//

import Foundation
import Testing
@testable import Clawline

@Suite(.serialized)
struct UploadServiceTests {
    @MainActor
    @Test("Upload uses HTTPS provider API URL for non-local stored HTTP base")
    func uploadUsesHTTPSProviderAPIURLForNonLocalStoredHTTPBase() async throws {
        let requestRecorder = RequestRecorder()
        let service = UploadService(
            auth: T1517UploadAuthManager(),
            baseURLProvider: { URL(string: "http://100.85.66.60:18800") },
            session: Self.stubbedSession { request in
                await requestRecorder.record(request)
                let data = #"{"assetId":"asset_grouped_1","mimeType":"image/png"}"#.data(using: .utf8) ?? Data()
                return Self.response(statusCode: 200, url: request.url, data: data)
            }
        )

        let assetId = try await service.upload(data: Data([0x89, 0x50, 0x4E, 0x47]), mimeType: "image/png", filename: "group.png")

        let request = try #require(await requestRecorder.firstRequest)
        #expect(assetId == "asset_grouped_1")
        #expect(request.url?.absoluteString == "https://tars.tail4105e8.ts.net:19443/upload")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer jwt")
    }

    @MainActor
    @Test("Download uses HTTPS provider API URL for websocket-derived non-local HTTP base")
    func downloadUsesHTTPSProviderAPIURLForWebSocketDerivedNonLocalHTTPBase() async throws {
        let requestRecorder = RequestRecorder()
        let service = UploadService(
            auth: T1517UploadAuthManager(),
            baseURLProvider: { URL(string: "http://example.com:18800") },
            session: Self.stubbedSession { request in
                await requestRecorder.record(request)
                return Self.response(statusCode: 200, url: request.url, data: Data([1, 2, 3]))
            }
        )

        let data = try await service.download(assetId: "asset/group 1")

        let request = try #require(await requestRecorder.firstRequest)
        #expect(data == Data([1, 2, 3]))
        #expect(request.url?.absoluteString == "https://example.com:19443/download/asset%2Fgroup%201")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer jwt")
    }

    @Test("Resolver preserves explicit local HTTP provider API URLs")
    func resolverPreservesExplicitLocalHTTPProviderAPIURLs() throws {
        let uploadURL = ProviderHTTPURLResolver.uploadURL(from: try #require(URL(string: "http://localhost:18800")))
        let downloadURL = try ProviderHTTPURLResolver.downloadURL(
            from: try #require(URL(string: "http://127.0.0.1:18800/api")),
            assetId: "asset 1"
        )

        #expect(uploadURL.absoluteString == "http://localhost:18800/upload")
        #expect(downloadURL.absoluteString == "http://127.0.0.1:18800/api/download/asset%201")
    }

    private static func stubbedSession(
        handler: @escaping @Sendable (URLRequest) async throws -> (HTTPURLResponse, Data)
    ) -> URLSession {
        T1517UploadStubURLProtocol.requestHandler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [T1517UploadStubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func response(statusCode: Int, url: URL?, data: Data) -> (HTTPURLResponse, Data) {
        (
            HTTPURLResponse(
                url: url ?? URL(string: "https://example.com")!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!,
            data
        )
    }
}

@MainActor
private final class T1517UploadAuthManager: AuthManaging {
    var isAuthenticated: Bool = true
    var currentUserId: String? = "user"
    var token: String? = "jwt"
    var isAdmin: Bool = false

    func storeCredentials(token: String, userId: String) {
        self.token = token
        currentUserId = userId
        isAuthenticated = true
    }

    func updateAdminStatus(_ isAdmin: Bool) {
        self.isAdmin = isAdmin
    }

    func refreshAdminStatusFromToken() {}

    func clearCredentials() {
        token = nil
        currentUserId = nil
        isAuthenticated = false
        isAdmin = false
    }
}

private actor RequestRecorder {
    private var requests: [URLRequest] = []

    var firstRequest: URLRequest? {
        requests.first
    }

    func record(_ request: URLRequest) {
        requests.append(request)
    }
}

private final class T1517UploadStubURLProtocol: URLProtocol, @unchecked Sendable {
    static var requestHandler: (@Sendable (URLRequest) async throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: AttachmentError.networkFailure)
            return
        }
        Task {
            do {
                let (response, data) = try await handler(request)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }
    }

    override func stopLoading() {}
}
