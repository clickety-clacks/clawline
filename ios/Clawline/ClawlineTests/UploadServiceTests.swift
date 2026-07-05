import Foundation
import Observation
import Testing
@testable import Clawline

@Suite(.serialized)
struct UploadServiceTests {
    @Test("T1517 upload upgrades known TARS HTTP provider URL before posting asset")
    @MainActor
    func uploadUsesHTTPSGatewayForKnownTARSHTTPBaseURL() async throws {
        let auth = UploadTestAuthManager()
        auth.storeCredentials(token: "token", userId: "user")
        let capture = RequestCapture()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UploadCaptureURLProtocol.self]
        UploadCaptureURLProtocol.handler = { request in
            capture.record(request)
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://tars.tail4105e8.ts.net:19443/upload")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let data = #"{"assetId":"asset_1","mimeType":"image/jpeg"}"#.data(using: .utf8)!
            return (response, data)
        }
        defer { UploadCaptureURLProtocol.handler = nil }

        let service = UploadService(
            auth: auth,
            baseURLProvider: { URL(string: "http://100.85.66.60:18800") },
            session: URLSession(configuration: configuration)
        )

        let assetId = try await service.upload(data: Data([0x01, 0x02]), mimeType: "image/jpeg", filename: "group-1.jpg")

        #expect(assetId == "asset_1")
        #expect(capture.request?.url?.absoluteString == "https://tars.tail4105e8.ts.net:19443/upload")
        #expect(capture.request?.httpMethod == "POST")
    }

    @Test("T1517 download upgrades known TARS HTTP provider URL before fetching asset")
    @MainActor
    func downloadUsesHTTPSGatewayForKnownTARSHTTPBaseURL() async throws {
        let auth = UploadTestAuthManager()
        auth.storeCredentials(token: "token", userId: "user")
        let capture = RequestCapture()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UploadCaptureURLProtocol.self]
        UploadCaptureURLProtocol.handler = { request in
            capture.record(request)
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://tars.tail4105e8.ts.net:19443/download/asset_1")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "image/jpeg"]
            )!
            return (response, Data([0x03, 0x04]))
        }
        defer { UploadCaptureURLProtocol.handler = nil }

        let service = UploadService(
            auth: auth,
            baseURLProvider: { URL(string: "http://100.85.66.60:18800") },
            session: URLSession(configuration: configuration)
        )

        let data = try await service.download(assetId: "asset_1")

        #expect(data == Data([0x03, 0x04]))
        #expect(capture.request?.url?.absoluteString == "https://tars.tail4105e8.ts.net:19443/download/asset_1")
        #expect(capture.request?.httpMethod == "GET")
    }

    @Test("T1517 generic HTTP provider URL is not rewritten")
    func genericHTTPBaseURLIsPreserved() throws {
        let original = try #require(URL(string: "http://example.test:18800"))
        #expect(ProviderHTTPURLPolicy.appVisibleBaseURL(from: original).absoluteString == "http://example.test:18800")
    }
}

private final class RequestCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storedRequest: URLRequest?

    var request: URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return storedRequest
    }

    func record(_ request: URLRequest) {
        lock.lock()
        storedRequest = request
        lock.unlock()
    }
}

private final class UploadCaptureURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

@MainActor
@Observable
private final class UploadTestAuthManager: AuthManaging {
    var isAuthenticated: Bool = false
    var currentUserId: String?
    var token: String?
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
