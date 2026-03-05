//
//  SalientHighlightService.swift
//  Clawline
//
//  On-device salient phrase highlighting using Apple Intelligence Foundation Models.
//

import CryptoKit
import Foundation
import OSLog
import QuartzCore

#if canImport(FoundationModels)
import FoundationModels
#endif

extension Notification.Name {
    static let salientHighlightScrollingChanged = Notification.Name("co.clicketyclacks.Clawline.salientHighlight.scrollingChanged")
}

final class SalientHighlightService: SalientHighlightServicing {
    nonisolated fileprivate static let logger = Logger(subsystem: "co.clicketyclacks.Clawline", category: "SalientHighlight")

    // Bump to invalidate all cached results.
    private static let algorithmVersion = 3

    // Keep memory cache modest; disk cache handles long histories.
    private let memoryCache: NSCache<NSString, SalientHighlightsBox> = {
        let cache = NSCache<NSString, SalientHighlightsBox>()
        cache.countLimit = 600
        return cache
    }()
    private let worker = Worker()
    private var scrollObserver: NSObjectProtocol?

    init() {
        scrollObserver = NotificationCenter.default.addObserver(
            forName: .salientHighlightScrollingChanged,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            guard let isScrolling = note.userInfo?["isScrolling"] as? Bool else { return }
            Task { await self.worker.setIsUserScrolling(isScrolling) }
        }
    }

    deinit {
        if let scrollObserver {
            NotificationCenter.default.removeObserver(scrollObserver)
        }
    }

    func cachedHighlights(messageId: String, renderedText: String) -> SalientHighlights? {
        let key = CacheKey(messageId: messageId, renderedTextHash: Self.sha256Hex(renderedText), algorithmVersion: Self.algorithmVersion)
        return memoryCache.object(forKey: Self.memoryKey(for: key))?.value
    }

    func highlights(messageId: String, renderedText: String) async -> SalientHighlights? {
        let key = CacheKey(messageId: messageId, renderedTextHash: Self.sha256Hex(renderedText), algorithmVersion: Self.algorithmVersion)
        if let cached = memoryCache.object(forKey: Self.memoryKey(for: key))?.value { return cached }

        if let cached = await worker.loadFromDisk(key: key, renderedText: renderedText) {
            memoryCache.setObject(SalientHighlightsBox(cached), forKey: Self.memoryKey(for: key))
            return cached
        }

        guard await worker.canGenerate() else {
            return nil
        }

        // Keep model input bounded; we still resolve candidates against the *full* rendered text.
        let analysisText = Self.boundedInput(renderedText)
        let generated = await worker.generate(
            messageId: messageId,
            analysisText: analysisText,
            renderedTextForResolution: renderedText,
            renderedTextHash: key.renderedTextHash,
            algorithmVersion: Self.algorithmVersion
        )
        if let generated {
            memoryCache.setObject(SalientHighlightsBox(generated), forKey: Self.memoryKey(for: key))
        }
        return generated
    }

    private static func boundedInput(_ text: String) -> String {
        // UTF-16 bound for predictable interaction with NSString ranges.
        let maxUTF16 = 6_000
        let ns = text as NSString
        if ns.length <= maxUTF16 { return text }

        // Sample the beginning and end to preserve decisions/questions often found near either.
        let headLen = maxUTF16 / 2
        let tailLen = maxUTF16 - headLen
        let head = ns.substring(with: NSRange(location: 0, length: headLen))
        let tail = ns.substring(with: NSRange(location: ns.length - tailLen, length: tailLen))
        return head + "\n...\n" + tail
    }

    nonisolated static func sha256Hex(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    private static func memoryKey(for key: CacheKey) -> NSString {
        "\(key.messageId)|\(key.renderedTextHash)|\(key.algorithmVersion)" as NSString
    }
}

private final class SalientHighlightsBox: NSObject {
    let value: SalientHighlights
    init(_ value: SalientHighlights) { self.value = value }
}

extension SalientHighlightService: @unchecked Sendable {}

// MARK: - Worker

private actor Worker {
    private let maxConcurrentGenerations = 2
    private let maxInFlightGenerations = 10
    private var availablePermits = 2
    private struct Waiter: Equatable {
        let id: UUID
        let continuation: CheckedContinuation<Void, Never>
        static func == (lhs: Waiter, rhs: Waiter) -> Bool { lhs.id == rhs.id }
    }
    private var permitWaiters: [Waiter] = []
    private var isUserScrolling: Bool = false
    private var nextPermitGrantTime: CFTimeInterval = 0
    private static let permitThrottleSeconds: CFTimeInterval = 0.15
    private var throttleWakeTask: Task<Void, Never>?
    private var permitGrantScheduled: Bool = false
    private var inFlight: [SalientHighlightService.CacheKey: Task<SalientHighlights?, Never>] = [:]

    private let fileManager = FileManager.default
    private let baseURL: URL

    init() {
        let caches: URL
        if let directory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first {
            caches = directory
        } else {
            caches = fileManager.temporaryDirectory
        }
        baseURL = caches.appendingPathComponent("SalientHighlights/v1", isDirectory: true)
    }

    func setIsUserScrolling(_ isScrolling: Bool) {
        if isUserScrolling == isScrolling { return }
        isUserScrolling = isScrolling
        if !isUserScrolling {
            schedulePermitGrant()
        }
    }

    func canGenerate() async -> Bool {
#if canImport(FoundationModels)
        if #available(iOS 26.0, visionOS 3.0, *) {
            let model = SystemLanguageModel.default
            switch model.availability {
            case .available:
                return true
            case .unavailable:
                return false
            }
        }
#endif
        return false
    }

    func loadFromDisk(key: SalientHighlightService.CacheKey, renderedText: String) async -> SalientHighlights? {
        do {
            try ensureBaseDir()
            let url = cacheURL(for: key)
            guard fileManager.fileExists(atPath: url.path) else { return nil }

            // Disk I/O off the main actor.
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            let decoded = try JSONDecoder().decode(SalientHighlights.self, from: data)
            guard decoded.algorithmVersion == key.algorithmVersion else { return nil }
            guard decoded.renderedTextHash == key.renderedTextHash else { return nil }
            guard decoded.renderedTextLengthUTF16 == (renderedText as NSString).length else { return nil }
            return decoded
        } catch {
            SalientHighlightService.logger.debug("disk_cache_load_failed err=\(String(describing: error), privacy: .public)")
            return nil
        }
    }

    func generate(messageId: String,
                  analysisText: String,
                  renderedTextForResolution: String,
                  renderedTextHash: String,
                  algorithmVersion: Int) async -> SalientHighlights? {
        let key = SalientHighlightService.CacheKey(messageId: messageId, renderedTextHash: renderedTextHash, algorithmVersion: algorithmVersion)
        if let existing = inFlight[key] {
            return await existing.value
        }
        if inFlight.count >= maxInFlightGenerations {
            SalientHighlightService.logger.debug("generation_skipped_backpressure in_flight=\(self.inFlight.count, privacy: .public)")
            return nil
        }

        let task = Task { [analysisText, renderedTextForResolution] in
            await self.performGeneration(
                messageId: messageId,
                analysisText: analysisText,
                renderedTextForResolution: renderedTextForResolution,
                renderedTextHash: renderedTextHash,
                algorithmVersion: algorithmVersion
            )
        }

        inFlight[key] = task
        let result = await task.value
        inFlight.removeValue(forKey: key)

        if let result {
            do {
                try ensureBaseDir()
                let url = cacheURL(for: key)
                let data = try JSONEncoder().encode(result)
                try data.write(to: url, options: [.atomic])
            } catch {
                SalientHighlightService.logger.debug("disk_cache_write_failed err=\(String(describing: error), privacy: .public)")
            }
        }
        return result
    }

    private func ensureBaseDir() throws {
        if !fileManager.fileExists(atPath: baseURL.path) {
            try fileManager.createDirectory(at: baseURL, withIntermediateDirectories: true)
        }
    }

    private func cacheURL(for key: SalientHighlightService.CacheKey) -> URL {
        // Avoid leaking message IDs into the filesystem.
        let idHash = SalientHighlightService.sha256Hex(key.messageId).prefix(16)
        let textHash = key.renderedTextHash.prefix(16)
        let name = "m_\(idHash)_t_\(textHash)_a\(key.algorithmVersion).json"
        return baseURL.appendingPathComponent(name)
    }

    private func acquirePermit() async {
        let waiterId = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { cont in
                permitWaiters.append(Waiter(id: waiterId, continuation: cont))
                // Allow multiple requests to enqueue before we pick the next one to run.
                // This makes the effective ordering LIFO (newest wins) rather than FIFO.
                schedulePermitGrant()
            }
        } onCancel: {
            Task { await self.cancelPermitWaiter(id: waiterId) }
        }
    }

    private func releasePermit() {
        availablePermits = min(maxConcurrentGenerations, availablePermits + 1)
        schedulePermitGrant()
    }

    private func cancelPermitWaiter(id: UUID) {
        // Best-effort: if the awaiting task was cancelled before being granted a permit,
        // remove its waiter so we don't leak an unresumable continuation.
        if let idx = permitWaiters.lastIndex(where: { $0.id == id }) {
            permitWaiters.remove(at: idx)
        }
    }

    private func schedulePermitGrant() {
        if permitGrantScheduled { return }
        permitGrantScheduled = true
        Task {
            // Ensure we don't grant permits inline on the first enqueued request.
            await Task.yield()
            await self.runPermitGrant()
        }
    }

    private func runPermitGrant() {
        permitGrantScheduled = false
        tryGrantPermits()
    }

    private func tryGrantPermits() {
        guard !isUserScrolling else { return }
        guard availablePermits > 0 else { return }
        guard !permitWaiters.isEmpty else { return }

        let now = CACurrentMediaTime()
        if now < nextPermitGrantTime {
            // Ensure only one wake task is scheduled while we're throttling.
            if throttleWakeTask == nil {
                let delay = nextPermitGrantTime - now
                throttleWakeTask = Task { [delay] in
                    do {
                        try await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
                    } catch is CancellationError {
                        self.clearThrottleWake()
                        return
                    } catch {
                        self.clearThrottleWake()
                        return
                    }
                    self.clearThrottleWake()
                    guard !Task.isCancelled else { return }
                    self.schedulePermitGrant()
                }
            }
            return
        }

        // Throttle: grant at most one permit every ~150ms to avoid saturating Foundation Models
        // and starving the UI during cache invalidation.
        nextPermitGrantTime = now + Self.permitThrottleSeconds

        availablePermits -= 1
        // LIFO: newest requests (typically bottom/most recent) get serviced first.
        let waiter = permitWaiters.removeLast()
        waiter.continuation.resume()

        // Drain the queue (respecting throttle + scrolling). Without this, a backlog can stall
        // if no new requests or permit releases occur after the first grant.
        if availablePermits > 0, !permitWaiters.isEmpty {
            schedulePermitGrant()
        }
    }

    private func clearThrottleWake() {
        throttleWakeTask = nil
    }

    private func performGeneration(
        messageId: String,
        analysisText: String,
        renderedTextForResolution: String,
        renderedTextHash: String,
        algorithmVersion: Int
    ) async -> SalientHighlights? {
        await acquirePermit()
        defer { releasePermit() }

        guard !analysisText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

#if canImport(FoundationModels)
        if #available(iOS 26.0, visionOS 3.0, *) {
            let model = SystemLanguageModel.default
            guard case .available = model.availability else { return nil }

            let instructions = """
            You identify the core salience of a message so someone can scan chat history quickly.
            Highlight as little as possible while still conveying the essential point.
            Prefer action phrases that preserve intent: include verb + object together (for example, "write the report"), not isolated nouns.
            If there is no action, return the minimal phrase that captures the key decision, question, or fact.
            Each candidate must be an exact substring copied from the input text.
            Do NOT highlight filler, process/meta questions, or scattered adjectives.
            Do NOT return overlapping candidates.
            kind must be one of: decision, question, fact, actionItem (classification only).
            confidence must be 0.0 to 1.0.
            If nothing is salient, return an empty candidates list.
            """

            let session = LanguageModelSession(instructions: instructions)
            let prompt = """
            Identify the core salient phrase(s) from this message.
            Return only the minimal exact substring(s) needed to communicate the essential point.

            \"\"\"\n\(analysisText)\n\"\"\"
            """

            let t0 = CFAbsoluteTimeGetCurrent()
            do {
                let response = try await session.respond(to: prompt, generating: SalientOutput.self)
                let dt = CFAbsoluteTimeGetCurrent() - t0
                SalientHighlightService.logger.debug("model_ok dt=\(dt, privacy: .public) chars=\(analysisText.count, privacy: .public)")
                return Self.resolveCandidates(
                    messageId: messageId,
                    renderedText: renderedTextForResolution,
                    renderedTextHash: renderedTextHash,
                    algorithmVersion: algorithmVersion,
                    candidates: response.content.candidates
                )
            } catch {
                let dt = CFAbsoluteTimeGetCurrent() - t0
                SalientHighlightService.logger.debug("model_err dt=\(dt, privacy: .public) err=\(String(describing: error), privacy: .public)")
                return nil
            }
        }
#endif
        return nil
    }

#if canImport(FoundationModels)
    @available(iOS 26.0, visionOS 3.0, *)
    private static func resolveCandidates(messageId: String,
                                          renderedText: String,
                                          renderedTextHash: String,
                                          algorithmVersion: Int,
                                          candidates: [SalientOutput.Candidate]) -> SalientHighlights {
        let ns = renderedText as NSString
        let fullLen = ns.length

        var spans: [SalientSpan] = []
        spans.reserveCapacity(candidates.count)

        for candidate in candidates {
            let raw = candidate.substring.trimmingCharacters(in: .whitespacesAndNewlines)
            guard raw.count >= 3 else { continue }
            guard raw.rangeOfCharacter(from: .alphanumerics) != nil else { continue }

            let range = ns.range(of: raw)
            guard range.location != NSNotFound, range.length > 0 else { continue }
            guard range.location + range.length <= fullLen else { continue }

            let kind = SalientSpan.Kind(rawValue: candidate.kind)
            spans.append(
                SalientSpan(
                    startUTF16: range.location,
                    lengthUTF16: range.length,
                    style: .bold,
                    kind: kind,
                    confidence: candidate.confidence
                )
            )
        }

        spans = normalize(spans: spans, maxLength: fullLen)
        return SalientHighlights(
            messageId: messageId,
            renderedTextHash: renderedTextHash,
            renderedTextLengthUTF16: fullLen,
            algorithmVersion: algorithmVersion,
            spans: spans
        )
    }
#endif

    private static func normalize(spans: [SalientSpan], maxLength: Int) -> [SalientSpan] {
        // Sort by position, then prefer longer/higher-confidence spans within overlaps.
        let sorted = spans
            .filter { $0.startUTF16 >= 0 && $0.lengthUTF16 > 0 && ($0.startUTF16 + $0.lengthUTF16) <= maxLength }
            .sorted { a, b in
                if a.startUTF16 != b.startUTF16 { return a.startUTF16 < b.startUTF16 }
                if a.lengthUTF16 != b.lengthUTF16 { return a.lengthUTF16 > b.lengthUTF16 }
                return (a.confidence ?? 0) > (b.confidence ?? 0)
            }

        var result: [SalientSpan] = []
        for span in sorted {
            let start = span.startUTF16
            let end = start + span.lengthUTF16
            if result.contains(where: { existing in
                let s = existing.startUTF16
                let e = s + existing.lengthUTF16
                return max(s, start) < min(e, end)
            }) {
                continue
            }
            result.append(span)
        }
        return result
    }
}

// MARK: - Foundation Models Schema

#if canImport(FoundationModels)
@available(iOS 26.0, visionOS 3.0, *)
@Generable
private struct SalientOutput {
    @Guide(description: "Candidates to emphasize; each must be an exact substring of the input text.")
    var candidates: [Candidate]

    @Generable
    struct Candidate {
        @Guide(description: "Exact substring copied from the input text. Keep it short.")
        var substring: String

        @Guide(description: "decision, question, fact, actionItem")
        var kind: String

        @Guide(description: "0.0-1.0 confidence")
        var confidence: Double
    }
}
#endif

// MARK: - Cache Key + Helpers

extension SalientHighlightService {
    fileprivate struct CacheKey: Hashable {
        var messageId: String
        var renderedTextHash: String
        var algorithmVersion: Int
    }
}
