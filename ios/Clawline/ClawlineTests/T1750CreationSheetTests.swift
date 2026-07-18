//
//  T1750CreationSheetTests.swift
//  ClawlineTests
//
//  T-B: the tightbeam-only new-chat creation sheet. Covers the launch gate
//  (openclaw keeps the name-only direct create), the archetype→where host
//  constraint (including the ["*"] wildcard), that a name-only create omits the
//  placement fields on the wire while a placement create carries all four, and
//  that a server refusal message is surfaced verbatim.
//

import Foundation
import Testing
@testable import Clawline

@Suite(.serialized)
struct T1750CreationSheetTests {
    // MARK: - launch gate (openclaw unchanged)

    @Test("T1750 openclaw keeps the name-only direct create; tightbeam opens the sheet")
    func launchPolicyGate() {
        #expect(StreamCreationLaunchPolicy.usesCreationSheet(isTightbeamServer: false) == false)
        #expect(StreamCreationLaunchPolicy.usesCreationSheet(isTightbeamServer: true) == true)
    }

    // MARK: - archetype → where host constraint

    @Test("T1750 no archetype offers the full assimilated host set")
    func hostsUnconstrainedWithoutArchetype() {
        #expect(
            StreamCreationHostConstraint.allowedHosts(hosts: ["eezo", "tars"], archetype: nil)
                == ["eezo", "tars"]
        )
    }

    @Test("T1750 a wildcard where offers every assimilated host")
    func hostsWildcard() throws {
        let archetype = try makeArchetype(name: "default", where: ["*"])
        #expect(
            StreamCreationHostConstraint.allowedHosts(hosts: ["eezo", "tars"], archetype: archetype)
                == ["eezo", "tars"]
        )
    }

    @Test("T1750 an explicit where constrains to the named hosts in assimilated order")
    func hostsConstrained() throws {
        let archetype = try makeArchetype(name: "eezo-only", where: ["eezo"])
        #expect(
            StreamCreationHostConstraint.allowedHosts(hosts: ["eezo", "tars"], archetype: archetype)
                == ["eezo"]
        )
    }

    @Test("T1750 where entries not in the assimilated set are ignored")
    func hostsWhereOutsideAssimilatedSet() throws {
        let archetype = try makeArchetype(name: "off-grid", where: ["mars"])
        #expect(
            StreamCreationHostConstraint.allowedHosts(hosts: ["eezo", "tars"], archetype: archetype)
                == []
        )
    }

    // MARK: - refusal surfaced verbatim

    @Test("T1750 a refusal message surfaces verbatim through StreamAPIError")
    func refusalVerbatimThroughStreamAPIError() {
        let rule = "host tars is not allowed by archetype default (where: eezo)"
        let error = StreamAPIError(code: "host_not_allowed", message: rule, statusCode: 422)
        #expect(error.errorDescription == rule)
        #expect(error.localizedDescription == rule)
    }

    @Test("T1750 a refusal message surfaces verbatim through the mapped provider error")
    func refusalVerbatimThroughProviderError() {
        // The provider maps StreamAPIError into serverError; the creation sheet
        // reads error.localizedDescription, so both must stay byte-for-byte.
        let rule = "handle 'main' is already taken"
        let error = ProviderChatService.Error.serverError(code: "handle_taken", message: rule)
        #expect(error.errorDescription == rule)
        #expect(error.localizedDescription == rule)
    }

    // MARK: - create request encoding on the wire

    @Test("T1750 a name-only create omits the placement fields")
    func createOmitsPlacementFields() async throws {
        let box = RequestBox()
        let urlSession = makeStubbedSession(capturing: box)
        let client = StreamAPIClient(baseURLProvider: { Self.baseURL }, session: urlSession)

        _ = try await client.createStream(
            displayName: "Stream 1",
            idempotencyKey: "req_name_only",
            token: "jwt"
        )

        let payload = try decodedBody(box)
        #expect(payload["displayName"] as? String == "Stream 1")
        #expect(payload["idempotencyKey"] as? String == "req_name_only")
        #expect(payload.keys.contains("harness") == false)
        #expect(payload.keys.contains("model") == false)
        #expect(payload.keys.contains("host") == false)
        #expect(payload.keys.contains("archetype") == false)
    }

    @Test("T1750 a placement create carries harness, model, host, and archetype")
    func createIncludesPlacementFields() async throws {
        let box = RequestBox()
        let urlSession = makeStubbedSession(capturing: box)
        let client = StreamAPIClient(baseURLProvider: { Self.baseURL }, session: urlSession)

        _ = try await client.createStream(
            displayName: "Stream 2",
            idempotencyKey: "req_placement",
            harness: "codex",
            model: "gpt-5.6-sol",
            host: "tars",
            archetype: "default",
            token: "jwt"
        )

        let payload = try decodedBody(box)
        #expect(payload["displayName"] as? String == "Stream 2")
        #expect(payload["idempotencyKey"] as? String == "req_placement")
        #expect(payload["harness"] as? String == "codex")
        #expect(payload["model"] as? String == "gpt-5.6-sol")
        #expect(payload["host"] as? String == "tars")
        #expect(payload["archetype"] as? String == "default")
    }

    // MARK: - helpers

    private static let baseURL = URL(string: "http://127.0.0.1:18800")!

    private final class RequestBox: @unchecked Sendable {
        var body: Data?
        var path: String?
    }

    private func makeArchetype(name: String, where whereHosts: [String]) throws -> OrgOptions.Archetype {
        let whereData = try JSONSerialization.data(withJSONObject: whereHosts)
        let whereJSON = String(decoding: whereData, as: UTF8.self)
        let json = "{ \"name\": \"\(name)\", \"where\": \(whereJSON) }"
        return try JSONDecoder().decode(OrgOptions.Archetype.self, from: Data(json.utf8))
    }

    private func makeStubbedSession(capturing box: RequestBox) -> URLSession {
        CreateStreamStubURLProtocol.requestHandler = { request in
            box.path = request.url?.path
            box.body = request.httpBody ?? Self.bodyData(from: request.httpBodyStream)
            let data = #"""
            {
              "stream": {
                "sessionKey": "agent:main:clawline:user:s_created",
                "displayName": "Created",
                "kind": "custom",
                "orderIndex": 1,
                "isBuiltIn": false,
                "createdAt": 1700000000000,
                "updatedAt": 1700000000000
              }
            }
            """#.data(using: .utf8) ?? Data()
            return (
                HTTPURLResponse(
                    url: request.url ?? Self.baseURL,
                    statusCode: 201,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                data
            )
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CreateStreamStubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func decodedBody(_ box: RequestBox) throws -> [String: Any] {
        #expect(box.path == "/api/streams")
        let body = try #require(box.body)
        let json = try JSONSerialization.jsonObject(with: body)
        return try #require(json as? [String: Any])
    }

    private static func bodyData(from stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { return nil }
            if count == 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

private final class CreateStreamStubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
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
