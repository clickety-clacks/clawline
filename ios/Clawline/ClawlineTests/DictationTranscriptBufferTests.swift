import Foundation
import Testing
@testable import Clawline

struct DictationTranscriptBufferTests {
    @Test("Endpoint commits current segment and clears provisional text")
    func endpointCommitsCurrentSegment() {
        let buffer = DictationTranscriptBuffer()

        let update = buffer.apply(tokens: [
            SonioxTranscriptToken(text: "hello ", isFinal: true),
            SonioxTranscriptToken(text: "wor", isFinal: false),
            SonioxTranscriptToken(text: "<end>", isFinal: true)
        ], finished: false)

        #expect(update.committedSegments == ["hello wor"])
        #expect(update.provisionalText.isEmpty)
        #expect(update.sawEndpoint == true)
        #expect(update.hadAnyTokens == true)
    }

    @Test("Multiple endpoints in one update emit multiple committed segments")
    func multipleEndpointCommits() {
        let buffer = DictationTranscriptBuffer()

        let update = buffer.apply(tokens: [
            SonioxTranscriptToken(text: "alpha", isFinal: true),
            SonioxTranscriptToken(text: "<end>", isFinal: true),
            SonioxTranscriptToken(text: "beta", isFinal: true),
            SonioxTranscriptToken(text: "<end>", isFinal: true),
            SonioxTranscriptToken(text: " gamma", isFinal: false)
        ], finished: false)

        #expect(update.committedSegments == ["alpha", "beta"])
        #expect(update.provisionalText == " gamma")
        #expect(update.sawEndpoint == true)
    }

    @Test("Marker-only updates still report token activity")
    func markerOnlyUpdatesReportActivity() {
        let buffer = DictationTranscriptBuffer()
        let update = buffer.apply(tokens: [
            SonioxTranscriptToken(text: "<fin>", isFinal: true)
        ], finished: false)

        #expect(update.hadAnyTokens == true)
        #expect(update.sawEndpoint == false)
        #expect(update.committedSegments.isEmpty)
        #expect(update.provisionalText.isEmpty)
    }
}
