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

    @Test("Incremental Soniox snapshots replace provisional text instead of accumulating")
    func incrementalSnapshotsReplaceProvisionalText() {
        let buffer = DictationTranscriptBuffer()

        let first = buffer.apply(tokens: [
            SonioxTranscriptToken(text: "Als", isFinal: false)
        ], finished: false)
        #expect(first.provisionalText == "Als")

        let second = buffer.apply(tokens: [
            SonioxTranscriptToken(text: "Also, ", isFinal: true),
            SonioxTranscriptToken(text: "dict", isFinal: false)
        ], finished: false)
        #expect(second.provisionalText == "Also, dict")

        let third = buffer.apply(tokens: [
            SonioxTranscriptToken(text: "Also, ", isFinal: true),
            SonioxTranscriptToken(text: "dictation", isFinal: false)
        ], finished: false)
        #expect(third.provisionalText == "Also, dictation")
        #expect(buffer.renderedText == "Also, dictation")
    }

    @Test("Mixed final and interim tokens preserve Soniox order")
    func mixedFinalAndInterimTokensPreserveOrder() {
        let buffer = DictationTranscriptBuffer()

        let update = buffer.apply(tokens: [
            SonioxTranscriptToken(text: "alpha ", isFinal: true),
            SonioxTranscriptToken(text: "beta ", isFinal: false),
            SonioxTranscriptToken(text: "gamma", isFinal: true)
        ], finished: false)

        #expect(update.provisionalText == "alpha beta gamma")
        #expect(buffer.renderedText == "alpha beta gamma")
    }

    @Test("Finalized token prefix remains owned when later interim updates omit it")
    func finalizedPrefixSurvivesInterimWindowUpdates() {
        let buffer = DictationTranscriptBuffer()

        let first = buffer.apply(tokens: [
            SonioxTranscriptToken(text: "The first half ", isFinal: true),
            SonioxTranscriptToken(text: "of the paragraph", isFinal: false)
        ], finished: false)
        #expect(first.provisionalText == "The first half of the paragraph")

        let second = buffer.apply(tokens: [
            SonioxTranscriptToken(text: "keeps growing", isFinal: false)
        ], finished: false)

        #expect(second.provisionalText == "The first half keeps growing")
        #expect(buffer.renderedText == "The first half keeps growing")
    }

    @Test("Advanced window newly final tokens extend retained final prefix")
    func advancedWindowFinalTokensExtendRetainedFinalPrefix() {
        let buffer = DictationTranscriptBuffer()

        let first = buffer.apply(tokens: [
            SonioxTranscriptToken(text: "The first half ", isFinal: true),
            SonioxTranscriptToken(text: "of the paragraph", isFinal: false)
        ], finished: false)
        #expect(first.provisionalText == "The first half of the paragraph")

        let second = buffer.apply(tokens: [
            SonioxTranscriptToken(text: "of the paragraph ", isFinal: true),
            SonioxTranscriptToken(text: "continues", isFinal: false)
        ], finished: false)

        #expect(second.provisionalText == "The first half of the paragraph continues")
        #expect(buffer.renderedText == "The first half of the paragraph continues")
    }

    @Test("Advanced window does not collapse repeated boundary text")
    func advancedWindowDoesNotCollapseRepeatedBoundaryText() {
        let buffer = DictationTranscriptBuffer()

        let first = buffer.apply(tokens: [
            SonioxTranscriptToken(text: "Tibet ", isFinal: true),
            SonioxTranscriptToken(text: "bet", isFinal: false)
        ], finished: false)
        #expect(first.provisionalText == "Tibet bet")

        let second = buffer.apply(tokens: [
            SonioxTranscriptToken(text: "bet on it ", isFinal: true),
            SonioxTranscriptToken(text: "again", isFinal: false)
        ], finished: false)

        #expect(second.provisionalText == "Tibet bet on it again")
        #expect(buffer.renderedText == "Tibet bet on it again")
    }
}
