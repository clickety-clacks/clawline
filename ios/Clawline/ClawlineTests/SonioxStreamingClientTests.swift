import Foundation
import Testing
@testable import Clawline

struct SonioxStreamingClientTests {
    @Test("Decodes numeric Soniox error_code as string")
    func decodesNumericErrorCode() throws {
        let client = SonioxStreamingClient()
        let response = try client.decodeResponseText(
            #"{"tokens":[],"finished":false,"error_code":408,"error_message":"input_too_slow"}"#
        )

        #expect(response.errorCode == "408")
        #expect(response.errorMessage == "input_too_slow")
    }

    @Test("Decodes string Soniox error_code unchanged")
    func decodesStringErrorCode() throws {
        let client = SonioxStreamingClient()
        let response = try client.decodeResponseText(
            #"{"tokens":[],"finished":false,"error_code":"input_too_slow","error_message":null}"#
        )

        #expect(response.errorCode == "input_too_slow")
        #expect(response.errorMessage == nil)
    }
}
