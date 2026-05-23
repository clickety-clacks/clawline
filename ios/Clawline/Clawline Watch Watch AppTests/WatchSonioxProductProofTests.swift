import Foundation
import Testing
@testable import Clawline_Watch_Watch_App

#if SONIOX_PRODUCT_PROOF
@Suite(.serialized)
struct WatchSonioxProductProofTests {
    @Test("SonioxStreamingClient proof source streams audio to Soniox")
    @MainActor
    func sonioxStreamingClientProofSourceStreamsAudioToSoniox() async throws {
        let (apiKey, runID, proofAudio) = try proofPrerequisites()
        let clientReferenceID = "watch-soniox-client-proof-\(runID)"
        let audioSource = WatchSonioxProofAudioSource(chunks: proofAudio.chunks(byteCount: 3_200))
        let sonioxClient = SonioxStreamingClient(audioSource: audioSource)
        let errors = WatchSonioxProofErrorLog()
        sonioxClient.onError = { error in
            errors.append(error)
        }

        try await sonioxClient.start(apiKey: apiKey, clientReferenceID: clientReferenceID)
        let didStream = try await waitUntil(timeout: .seconds(45)) {
            audioSource.didFinishStreaming
        }
        #expect(didStream)

        let transcript = await sonioxClient.finalize(timeoutNanoseconds: 15_000_000_000)
        print("WATCH_SONIOX_PRODUCT_PROOF runID=\(runID) clientReferenceID=\(clientReferenceID) bytes=\(audioSource.sentByteCount) transcript=\(transcript)")
        if !transcript.localizedCaseInsensitiveContains("clawline") {
            Issue.record("Expected Soniox transcript to contain Clawline; transcript=\(transcript) errors=\(errors.joinedMessages())")
        }
    }

    @Test("WatchVoiceSession product path streams proof audio to Soniox")
    @MainActor
    func watchVoiceSessionProductPathStreamsProofAudioToSoniox() async throws {
        let (apiKey, runID, proofAudio) = try proofPrerequisites()
        let clientReferenceID = "watch-soniox-voice-session-proof-\(runID)"

        let credentials = WatchCredentialStore(
            keychain: WatchKeychainStore(service: "WatchTests.sonioxProductProof", accessGroup: nil)
        )
        credentials.clear()
        credentials.apply(userInfo: ["sonioxApiKey": apiKey])

        let audioSource = WatchSonioxProofAudioSource(chunks: proofAudio.chunks(byteCount: 3_200))
        let sonioxClient = SonioxStreamingClient(audioSource: audioSource)
        let voiceSession = WatchVoiceSession(
            credentialStore: credentials,
            sonioxClient: sonioxClient,
            clientReferenceIDProvider: { clientReferenceID }
        )

        var sentTranscript: String?
        voiceSession.onTranscriptReady = { transcript in
            sentTranscript = transcript
        }

        voiceSession.startTap()
        let didStream = try await waitUntil(timeout: .seconds(45)) {
            audioSource.didFinishStreaming
        }
        guard didStream else {
            Issue.record(
                """
                Timed out waiting for proof audio source to finish streaming. \
                voiceState=\(voiceSession.voiceState) \
                visibleTranscript=\(voiceSession.transcript) \
                error=\(voiceSession.errorMessage ?? "nil") \
                sentBytes=\(audioSource.sentByteCount)
                """
            )
            return
        }

        voiceSession.stop()
        let didPublishTranscript = try await waitUntil(timeout: .seconds(15)) {
            sentTranscript?.localizedCaseInsensitiveContains("clawline") == true
        }

        if !didPublishTranscript {
            Issue.record(
                """
                Timed out waiting for WatchVoiceSession to publish final Soniox transcript. \
                voiceState=\(voiceSession.voiceState) \
                visibleTranscript=\(voiceSession.transcript) \
                sentTranscript=\(sentTranscript ?? "nil") \
                error=\(voiceSession.errorMessage ?? "nil") \
                sentBytes=\(audioSource.sentByteCount)
                """
            )
            return
        }

        #expect(voiceSession.errorMessage == nil)
        #expect(sentTranscript?.localizedCaseInsensitiveContains("clawline") == true)
        #expect(audioSource.startCallCount == 1)
        #expect(audioSource.sentByteCount == proofAudio.pcmData.count)
        print("WATCH_SONIOX_PRODUCT_PROOF runID=\(runID) clientReferenceID=\(clientReferenceID) bytes=\(audioSource.sentByteCount) transcript=\(sentTranscript ?? "")")
    }

    private func proofPrerequisites() throws -> (apiKey: String, runID: String, audio: WatchSonioxProofAudio) {
        let environment = ProcessInfo.processInfo.environment
        let apiKey = try #require(
            environment["SONIOX_E2E_API_KEY"] ?? environment["TEST_RUNNER_SONIOX_E2E_API_KEY"],
            "SONIOX_E2E_API_KEY is required for the Watch Soniox product proof."
        )
        #expect(!apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        let runID = try #require(
            environment["SONIOX_E2E_PROOF_RUN_ID"] ?? environment["TEST_RUNNER_SONIOX_E2E_PROOF_RUN_ID"],
            "SONIOX_E2E_PROOF_RUN_ID is required so stale test-runner credentials cannot satisfy the proof."
        )
        #expect(!runID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        let proofAudioURL = try #require(
            WatchSonioxProofBundle.proofAudioURL(),
            "watch-soniox-proof.wav must be bundled with the Watch app tests."
        )
        let proofAudio = try WatchSonioxProofAudio(url: proofAudioURL)
        #expect(proofAudio.sampleRate == 16_000)
        #expect(proofAudio.channelCount == 1)
        return (apiKey, runID, proofAudio)
    }

    private func waitUntil(timeout: Duration, condition: @escaping () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() {
                return true
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        return false
    }
}
#endif

private enum WatchSonioxProofBundle {
    static func proofAudioURL() -> URL? {
        let bundle = Bundle(for: WatchSonioxProofBundleToken.self)
        if let url = bundle.url(forResource: "watch-soniox-proof", withExtension: "wav") {
            return url
        }
        return bundle.url(forResource: "watch-soniox-proof", withExtension: "wav", subdirectory: "Resources")
    }
}

private final class WatchSonioxProofBundleToken {}

private final class WatchSonioxProofErrorLog {
    private let lock = NSLock()
    private var messages: [String] = []

    func append(_ error: Error) {
        lock.withLock {
            messages.append(String(describing: error))
        }
    }

    func joinedMessages() -> String {
        lock.withLock {
            messages.joined(separator: " | ")
        }
    }
}

private struct WatchSonioxProofAudio {
    let sampleRate: Int
    let channelCount: Int
    let pcmData: Data

    init(url: URL) throws {
        let data = try Data(contentsOf: url)
        let parser = try WAVParser(data: data)
        guard parser.audioFormat == 1, parser.bitsPerSample == 16 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        sampleRate = parser.sampleRate
        channelCount = parser.channelCount
        pcmData = parser.pcmData
    }

    func chunks(byteCount: Int) -> [Data] {
        var chunks: [Data] = []
        var offset = 0
        while offset < pcmData.count {
            let end = min(offset + byteCount, pcmData.count)
            chunks.append(pcmData.subdata(in: offset..<end))
            offset = end
        }
        return chunks
    }
}

private final class WatchSonioxProofAudioSource: SonioxAudioSource {
    var onAudioLevel: ((Float) -> Void)?

    private let chunks: [Data]
    private var task: Task<Void, Never>?
    private(set) var startCallCount = 0
    private(set) var sentByteCount = 0
    private(set) var didFinishStreaming = false

    init(chunks: [Data]) {
        self.chunks = chunks
    }

    func start(onPCMData: @escaping (Data) -> Void) throws {
        startCallCount += 1
        didFinishStreaming = false
        task?.cancel()
        task = Task { [chunks, weak self] in
            for chunk in chunks {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.sentByteCount += chunk.count
                    self?.onAudioLevel?(0.2)
                }
                onPCMData(chunk)
                do {
                    try await Task.sleep(for: .milliseconds(90))
                } catch {
                    return
                }
            }
            await MainActor.run {
                self?.didFinishStreaming = true
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}

private struct WAVParser {
    let audioFormat: Int
    let channelCount: Int
    let sampleRate: Int
    let bitsPerSample: Int
    let pcmData: Data

    init(data: Data) throws {
        guard data.count >= 44,
              data.asciiString(in: 0..<4) == "RIFF",
              data.asciiString(in: 8..<12) == "WAVE" else {
            throw CocoaError(.fileReadCorruptFile)
        }

        var offset = 12
        var parsedFormat: (format: Int, channels: Int, rate: Int, bits: Int)?
        var parsedPCM: Data?

        while offset + 8 <= data.count {
            let chunkID = data.asciiString(in: offset..<(offset + 4))
            let chunkSize = Int(data.littleEndianUInt32(at: offset + 4))
            let chunkStart = offset + 8
            let chunkEnd = chunkStart + chunkSize
            guard chunkEnd <= data.count else {
                throw CocoaError(.fileReadCorruptFile)
            }

            if chunkID == "fmt " {
                guard chunkSize >= 16 else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                parsedFormat = (
                    format: Int(data.littleEndianUInt16(at: chunkStart)),
                    channels: Int(data.littleEndianUInt16(at: chunkStart + 2)),
                    rate: Int(data.littleEndianUInt32(at: chunkStart + 4)),
                    bits: Int(data.littleEndianUInt16(at: chunkStart + 14))
                )
            } else if chunkID == "data" {
                parsedPCM = data.subdata(in: chunkStart..<chunkEnd)
            }

            offset = chunkEnd + (chunkSize % 2)
        }

        let format = try #require(parsedFormat)
        let pcm = try #require(parsedPCM)
        audioFormat = format.format
        channelCount = format.channels
        sampleRate = format.rate
        bitsPerSample = format.bits
        pcmData = pcm
    }
}

private extension Data {
    func asciiString(in range: Range<Int>) -> String? {
        guard range.lowerBound >= 0, range.upperBound <= count else { return nil }
        return String(data: subdata(in: range), encoding: .ascii)
    }

    func littleEndianUInt16(at offset: Int) -> UInt16 {
        self[offset..<(offset + 2)].enumerated().reduce(UInt16(0)) { result, element in
            result | (UInt16(element.element) << UInt16(element.offset * 8))
        }
    }

    func littleEndianUInt32(at offset: Int) -> UInt32 {
        self[offset..<(offset + 4)].enumerated().reduce(UInt32(0)) { result, element in
            result | (UInt32(element.element) << UInt32(element.offset * 8))
        }
    }
}
