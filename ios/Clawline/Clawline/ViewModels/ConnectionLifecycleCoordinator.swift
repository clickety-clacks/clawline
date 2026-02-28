import Foundation
import OSLog

enum ConnectionLifecyclePhase: Equatable {
    case idle
    case connecting
    case authenticating
    case replaying
    case live
    case recovering
    case failed
}

enum AuthFailureReason: Equatable {
    case rejected
    case sessionReplaced
    case tokenRevoked
    case protocolMismatch
}

enum TransportCloseReason: Equatable {
    case clean
    case error
    case keepaliveTimeout
}

struct LifecycleTransportEvent: Equatable {
    enum Payload: Equatable {
        case transportOpened
        case authResult(
            success: Bool,
            replayCount: Int?,
            replayTruncated: Bool?,
            historyReset: Bool?,
            failureReason: AuthFailureReason?
        )
        case serverMessage(data: Data)
        case transportClosed(reason: TransportCloseReason)
        case transportTimeout
    }

    let epoch: Int
    let payload: Payload
}

enum ConnectionLifecycleFailureReason: Equatable {
    case authRejected
    case sessionReplaced
    case tokenRevoked
    case protocolMismatch
    case protocolOverflow
    case historyResetTimeout
    case reconnectAttemptsExhausted
}

enum ConnectionLifecycleReason: Equatable {
    case appBackgrounded
    case appForegrounded
    case manualRetry
    case explicitTeardown
    case connectTimeout
    case authTimeout
    case replayTimeout
    case replayProgressTimeout
    case transportInterrupted
    case replayCompleted
    case authSucceeded
    case transportOpened
    case failure(ConnectionLifecycleFailureReason)
}

enum ConnectionLifecycleOutput: Equatable {
    case phaseTransition(
        from: ConnectionLifecyclePhase,
        to: ConnectionLifecyclePhase,
        epoch: Int,
        reason: ConnectionLifecycleReason
    )
    case restoreCacheRequested(epoch: Int)
    case historyResetRequired(epoch: Int)
    case replayStarted(epoch: Int, replayCount: Int, replayTruncated: Bool, historyReset: Bool)
    case serverMessage(epoch: Int, payload: Data)
    case replayCompleted(epoch: Int)
    case historyTruncated(epoch: Int)
}

actor ConnectionLifecycleCoordinator {
    typealias StartAttemptHandler = (_ epoch: Int, _ lastMessageId: String?, _ token: String) -> Void
    typealias StopAttemptHandler = () -> Void

    private let logger = Logger(subsystem: "co.clicketyclacks.Clawline", category: "ConnectionLifecycle")
    private let startAttempt: StartAttemptHandler
    private let stopAttempt: StopAttemptHandler
    private let randomJitterMs: () -> Int
    private let now: () -> Date

    private var continuation: AsyncStream<ConnectionLifecycleOutput>.Continuation?

    private(set) var phase: ConnectionLifecyclePhase = .idle
    private var currentEpoch: Int = 0
    private var authToken: String?
    private var reconnectEnabled: Bool = true
    private var canonicalCursor: String?

    private var reconnectTask: Task<Void, Never>?
    private var connectTimeoutTask: Task<Void, Never>?
    private var authTimeoutTask: Task<Void, Never>?
    private var replayTotalTimeoutTask: Task<Void, Never>?
    private var replayProgressTimeoutTask: Task<Void, Never>?
    private var historyResetAckTimeoutTask: Task<Void, Never>?

    private var replayExpectedCount: Int = 0
    private var replayRemainingCount: Int = 0
    private var replayTruncated: Bool = false
    private var replayStartAt: Date?
    private var replayOvershotEpoch: Int?
    private var consecutiveReplayOvershoots: Int = 0
    private var recoveringAttemptCount: Int = 0
    private var reconnectBackoff: Duration = .seconds(1)
    private var backgroundedAt: Date?
    private var awaitingHistoryResetAckEpoch: Int?
    private var bufferedServerMessages: [Data] = []

    init(
        startAttempt: @escaping StartAttemptHandler,
        stopAttempt: @escaping StopAttemptHandler,
        randomJitterMs: @escaping () -> Int = { Int.random(in: 0...1000) },
        now: @escaping () -> Date = Date.init
    ) {
        self.startAttempt = startAttempt
        self.stopAttempt = stopAttempt
        self.randomJitterMs = randomJitterMs
        self.now = now
    }

    var outputs: AsyncStream<ConnectionLifecycleOutput> {
        AsyncStream(bufferingPolicy: .unbounded) { continuation in
            self.continuation = continuation
        }
    }

    func setAuthToken(_ token: String?) {
        authToken = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        if authToken?.isEmpty == true {
            authToken = nil
        }
        if authToken == nil {
            resetRecoveringState()
            moveToIdleIfNeeded(reason: .explicitTeardown)
        }
    }

    func setReconnectEnabled(_ enabled: Bool) {
        reconnectEnabled = enabled
    }

    func seedCanonicalCursor(_ cursor: String?) {
        canonicalCursor = cursor
    }

    func updateCanonicalCursor(_ cursor: String?) {
        canonicalCursor = cursor
    }

    func appDidBecomeActive() {
        let lastBackgroundedAt = backgroundedAt
        if let lastBackgroundedAt, now().timeIntervalSince(lastBackgroundedAt) >= 60 {
            resetRecoveringState()
        }
        backgroundedAt = nil
        guard reconnectEnabled, phase == .idle else { return }
        let sinceBackground = now().timeIntervalSince(lastBackgroundedAt ?? .distantPast)
        if sinceBackground < 2 {
            reconnectTask?.cancel()
            reconnectTask = Task {
                do {
                    try await Task.sleep(for: .seconds(2 - sinceBackground))
                } catch {
                    return
                }
                await self.startIfNeeded()
            }
            return
        }
        startConnecting(reason: .appForegrounded)
    }

    func appDidEnterBackground() {
        backgroundedAt = now()
        cancelAllTimers()
        stopAttempt()
        moveToIdleIfNeeded(reason: .appBackgrounded)
    }

    func startIfNeeded() {
        guard reconnectEnabled, phase == .idle else { return }
        startConnecting(reason: .appForegrounded)
    }

    func reconnectIntentTransportInterrupted() {
        guard phase == .live || phase == .connecting || phase == .authenticating || phase == .replaying else {
            return
        }
        transition(to: .recovering, reason: .transportInterrupted)
        scheduleReconnect(after: reconnectBackoffWithJitter(), incrementRecoveringAttempt: true)
    }

    func manualRetry() {
        guard authToken != nil else { return }
        switch phase {
        case .failed:
            resetRecoveringState()
            startConnecting(reason: .manualRetry)
        case .recovering:
            reconnectTask?.cancel()
            reconnectTask = nil
            reconnectBackoff = .seconds(1)
            startConnecting(reason: .manualRetry)
        default:
            break
        }
    }

    func disconnectRequested() {
        stopAttempt()
        resetRecoveringState()
        moveToIdleIfNeeded(reason: .explicitTeardown)
    }

    func acknowledgeHistoryReset(epoch: Int) {
        guard awaitingHistoryResetAckEpoch == epoch else { return }
        awaitingHistoryResetAckEpoch = nil
        historyResetAckTimeoutTask?.cancel()
        historyResetAckTimeoutTask = nil
        beginReplay(epoch: epoch, historyReset: true)
        flushBufferedMessagesForEpoch(epoch)
    }

    func handleTransportEvent(_ event: LifecycleTransportEvent) {
        guard event.epoch == currentEpoch else {
            logger.info("lifecycle stale-event-drop eventEpoch=\(event.epoch) currentEpoch=\(self.currentEpoch)")
            return
        }
        guard phase != .idle && phase != .failed else {
            logger.info("lifecycle phase-gated-drop phase=\(String(describing: self.phase)) epoch=\(event.epoch)")
            return
        }
        switch event.payload {
        case .transportOpened:
            handleTransportOpened(epoch: event.epoch)
        case .authResult(let success, let replayCount, let replayTruncated, let historyReset, let failureReason):
            handleAuthResult(
                epoch: event.epoch,
                success: success,
                replayCount: replayCount,
                replayTruncated: replayTruncated,
                historyReset: historyReset,
                failureReason: failureReason
            )
        case .serverMessage(let data):
            handleServerMessage(epoch: event.epoch, data: data)
        case .transportClosed:
            handleTransportInterrupted(epoch: event.epoch)
        case .transportTimeout:
            handleTransportInterrupted(epoch: event.epoch)
        }
    }

    private func handleTransportOpened(epoch: Int) {
        guard phase == .connecting else { return }
        connectTimeoutTask?.cancel()
        connectTimeoutTask = nil
        transition(to: .authenticating, reason: .transportOpened)
        authTimeoutTask?.cancel()
        authTimeoutTask = Task {
            do {
                try await Task.sleep(for: .seconds(12))
            } catch {
                return
            }
            await self.handleAuthTimeout(epoch: epoch)
        }
    }

    private func handleAuthTimeout(epoch: Int) {
        guard currentEpoch == epoch, phase == .authenticating else { return }
        transition(to: .recovering, reason: .authTimeout)
        scheduleReconnect(after: reconnectBackoffWithJitter(), incrementRecoveringAttempt: true)
    }

    private func handleTransportInterrupted(epoch: Int) {
        guard currentEpoch == epoch else { return }
        switch phase {
        case .replaying, .live, .connecting, .authenticating:
            transition(to: .recovering, reason: .transportInterrupted)
            scheduleReconnect(after: reconnectBackoffWithJitter(), incrementRecoveringAttempt: true)
        default:
            break
        }
    }

    private func handleAuthResult(
        epoch: Int,
        success: Bool,
        replayCount: Int?,
        replayTruncated: Bool?,
        historyReset: Bool?,
        failureReason: AuthFailureReason?
    ) {
        if !success {
            switch failureReason {
            case .sessionReplaced:
                fail(.sessionReplaced)
                return
            case .tokenRevoked:
                fail(.tokenRevoked)
                return
            case .rejected:
                fail(.authRejected)
                return
            case .protocolMismatch:
                fail(.protocolMismatch)
                return
            case nil:
                break
            }
        }
        if phase == .recovering, success {
            reconnectTask?.cancel()
            reconnectTask = nil
            transition(to: .authenticating, reason: .authSucceeded)
        }
        guard phase == .authenticating else { return }
        authTimeoutTask?.cancel()
        authTimeoutTask = nil
        guard success else {
            switch failureReason {
            case .sessionReplaced:
                fail(.sessionReplaced)
            case .tokenRevoked:
                fail(.tokenRevoked)
            default:
                fail(.authRejected)
            }
            return
        }

        guard let replayCount, replayCount >= 0 else {
            fail(.protocolMismatch)
            return
        }

        replayExpectedCount = replayCount
        replayRemainingCount = replayCount
        self.replayTruncated = replayTruncated ?? false

        let shouldResetHistory = historyReset ?? false
        if shouldResetHistory {
            awaitingHistoryResetAckEpoch = epoch
            bufferedServerMessages.removeAll(keepingCapacity: false)
            emit(.historyResetRequired(epoch: epoch))
            historyResetAckTimeoutTask?.cancel()
            historyResetAckTimeoutTask = Task {
                do {
                    try await Task.sleep(for: .seconds(5))
                } catch {
                    return
                }
                await self.handleHistoryResetAckTimeout(epoch: epoch)
            }
            return
        }
        beginReplay(epoch: epoch, historyReset: false)
    }

    private func handleHistoryResetAckTimeout(epoch: Int) {
        guard awaitingHistoryResetAckEpoch == epoch else { return }
        fail(.historyResetTimeout)
    }

    private func beginReplay(epoch: Int, historyReset: Bool) {
        transition(to: .replaying, reason: .authSucceeded)
        replayStartAt = now()
        emit(
            .replayStarted(
                epoch: epoch,
                replayCount: replayExpectedCount,
                replayTruncated: replayTruncated,
                historyReset: historyReset
            )
        )

        if replayExpectedCount == 0 {
            completeReplay(epoch: epoch)
            return
        }

        let totalSeconds = min(300.0, max(30.0, Double(replayExpectedCount) * 0.25))
        replayTotalTimeoutTask?.cancel()
        replayTotalTimeoutTask = Task {
            do {
                try await Task.sleep(for: .seconds(totalSeconds))
            } catch {
                return
            }
            await self.handleReplayTotalTimeout(epoch: epoch)
        }
        resetReplayProgressTimeout(epoch: epoch)
    }

    private func flushBufferedMessagesForEpoch(_ epoch: Int) {
        guard currentEpoch == epoch else { return }
        let buffered = bufferedServerMessages
        bufferedServerMessages.removeAll(keepingCapacity: false)
        for payload in buffered {
            handleServerMessage(epoch: epoch, data: payload)
            if phase == .failed || phase == .recovering || phase == .idle {
                return
            }
        }
    }

    private func handleReplayTotalTimeout(epoch: Int) {
        guard currentEpoch == epoch, phase == .replaying else { return }
        transition(to: .recovering, reason: .replayTimeout)
        scheduleReconnect(after: reconnectBackoffWithJitter(), incrementRecoveringAttempt: true)
    }

    private func resetReplayProgressTimeout(epoch: Int) {
        replayProgressTimeoutTask?.cancel()
        replayProgressTimeoutTask = Task {
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                return
            }
            await self.handleReplayProgressTimeout(epoch: epoch)
        }
    }

    private func handleReplayProgressTimeout(epoch: Int) {
        guard currentEpoch == epoch, phase == .replaying, replayRemainingCount > 0 else { return }
        transition(to: .recovering, reason: .replayProgressTimeout)
        scheduleReconnect(after: reconnectBackoffWithJitter(), incrementRecoveringAttempt: true)
    }

    private func handleServerMessage(epoch: Int, data: Data) {
        guard currentEpoch == epoch else { return }
        if awaitingHistoryResetAckEpoch == epoch {
            bufferedServerMessages.append(data)
            if bufferedServerMessages.count > 500 {
                fail(.protocolOverflow)
            }
            return
        }
        guard phase == .replaying || phase == .live else { return }
        if phase == .live {
            emit(.serverMessage(epoch: epoch, payload: data))
            return
        }

        guard let replayDisposition = replayMessageDisposition(data: data) else {
            // Non-message envelopes are forwarded but do not decrement replay counters.
            emit(.serverMessage(epoch: epoch, payload: data))
            return
        }

        switch replayDisposition {
        case .invalidMessageEnvelope:
            transition(to: .recovering, reason: .failure(.protocolMismatch))
            scheduleReconnect(after: reconnectBackoffWithJitter(), incrementRecoveringAttempt: true)
        case .replayCounted:
            guard replayRemainingCount > 0 else {
                if replayOvershotEpoch != epoch {
                    replayOvershotEpoch = epoch
                    consecutiveReplayOvershoots += 1
                }
                if consecutiveReplayOvershoots >= 3 {
                    fail(.protocolMismatch)
                } else {
                    transition(to: .recovering, reason: .failure(.protocolMismatch))
                    scheduleReconnect(after: reconnectBackoffWithJitter(), incrementRecoveringAttempt: true)
                }
                return
            }
            replayRemainingCount -= 1
            emit(.serverMessage(epoch: epoch, payload: data))
            if replayRemainingCount > 0 {
                resetReplayProgressTimeout(epoch: epoch)
            } else {
                completeReplay(epoch: epoch)
            }
        }
    }

    private enum ReplayMessageDisposition {
        case replayCounted
        case invalidMessageEnvelope
    }

    private func replayMessageDisposition(data: Data) -> ReplayMessageDisposition? {
        struct Envelope: Decodable { let type: String }
        struct ServerMessageShape: Decodable {
            let type: String
            let id: String
            let role: String?
            let content: String
            let timestamp: Int64?
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
            return nil
        }
        guard envelope.type == "message" else {
            return nil
        }
        guard let decoded = try? JSONDecoder().decode(ServerMessageShape.self, from: data),
              decoded.type == "message",
              decoded.id.hasPrefix("s_") else {
            return .invalidMessageEnvelope
        }
        return .replayCounted
    }

    private func completeReplay(epoch: Int) {
        replayTotalTimeoutTask?.cancel()
        replayTotalTimeoutTask = nil
        replayProgressTimeoutTask?.cancel()
        replayProgressTimeoutTask = nil
        let replayDurationMs: Int = {
            guard let replayStartAt else { return 0 }
            return Int(now().timeIntervalSince(replayStartAt) * 1000)
        }()
        emit(.replayCompleted(epoch: epoch))
        transition(to: .live, reason: .replayCompleted)
        if replayTruncated {
            emit(.historyTruncated(epoch: epoch))
        }
        logger.info(
            "lifecycle replay-complete epoch=\(epoch) expected=\(self.replayExpectedCount) durationMs=\(replayDurationMs) replayTruncated=\(self.replayTruncated)"
        )
        consecutiveReplayOvershoots = 0
        replayOvershotEpoch = nil
        resetRecoveringState()
    }

    private func fail(_ reason: ConnectionLifecycleFailureReason) {
        transition(to: .failed, reason: .failure(reason))
        cancelAllTimers()
        stopAttempt()
        if reason == .sessionReplaced || reason == .authRejected || reason == .tokenRevoked {
            reconnectTask?.cancel()
            reconnectTask = nil
        }
    }

    private func startConnecting(reason: ConnectionLifecycleReason) {
        guard let authToken, !authToken.isEmpty else { return }
        switch phase {
        case .idle, .recovering, .failed:
            break
        default:
            return
        }
        reconnectTask?.cancel()
        reconnectTask = nil
        currentEpoch += 1
        let epoch = currentEpoch
        transition(to: .connecting, reason: reason, epochOverride: epoch)
        emit(.restoreCacheRequested(epoch: epoch))
        connectTimeoutTask?.cancel()
        connectTimeoutTask = Task {
            do {
                try await Task.sleep(for: .seconds(10))
            } catch {
                return
            }
            await self.handleConnectTimeout(epoch: epoch)
        }
        // Do not await between epoch increment and service dispatch.
        startAttempt(epoch, canonicalCursor, authToken)
    }

    private func handleConnectTimeout(epoch: Int) {
        guard currentEpoch == epoch, phase == .connecting else { return }
        transition(to: .recovering, reason: .connectTimeout)
        scheduleReconnect(after: reconnectBackoffWithJitter(), incrementRecoveringAttempt: true)
    }

    private func reconnectBackoffWithJitter() -> Duration {
        reconnectBackoff + .milliseconds(randomJitterMs())
    }

    private func scheduleReconnect(after delay: Duration, incrementRecoveringAttempt: Bool) {
        guard reconnectEnabled else { return }
        guard phase == .recovering else { return }
        guard reconnectTask == nil else { return }

        reconnectTask = Task {
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            await self.executeRecoveringReconnect(incrementRecoveringAttempt: incrementRecoveringAttempt)
        }
    }

    private func executeRecoveringReconnect(incrementRecoveringAttempt: Bool) {
        guard phase == .recovering else {
            reconnectTask = nil
            return
        }
        reconnectTask = nil
        if incrementRecoveringAttempt {
            recoveringAttemptCount += 1
            if recoveringAttemptCount >= 20 {
                fail(.reconnectAttemptsExhausted)
                return
            }
        }
        let previousBackoff = reconnectBackoff
        reconnectBackoff = min(previousBackoff * 2, .seconds(30))
        startConnecting(reason: .transportInterrupted)
        logger.info(
            "lifecycle reconnect-attempt index=\(self.recoveringAttemptCount) nextBackoffMs=\(Int(self.reconnectBackoff.components.seconds * 1000))"
        )
    }

    private func transition(to newPhase: ConnectionLifecyclePhase, reason: ConnectionLifecycleReason, epochOverride: Int? = nil) {
        guard phase != newPhase else { return }
        let from = phase
        guard isLegalTransition(from: from, to: newPhase) else {
            logger.info(
                "lifecycle invalid-transition from=\(String(describing: from)) to=\(String(describing: newPhase)) epoch=\(self.currentEpoch)"
            )
            return
        }
        phase = newPhase
        cancelPhaseTimers(for: from)
        emit(.phaseTransition(from: from, to: newPhase, epoch: epochOverride ?? currentEpoch, reason: reason))
        logger.info(
            "lifecycle phase-transition from=\(String(describing: from)) to=\(String(describing: newPhase)) epoch=\(epochOverride ?? self.currentEpoch)"
        )
    }

    private func moveToIdleIfNeeded(reason: ConnectionLifecycleReason) {
        switch phase {
        case .connecting, .authenticating, .replaying, .live, .recovering:
            transition(to: .idle, reason: reason)
        case .idle, .failed:
            break
        }
    }

    private func isLegalTransition(from: ConnectionLifecyclePhase, to: ConnectionLifecyclePhase) -> Bool {
        switch (from, to) {
        case (.idle, .connecting),
            (.connecting, .authenticating),
            (.connecting, .recovering),
            (.connecting, .failed),
            (.connecting, .idle),
            (.authenticating, .replaying),
            (.authenticating, .recovering),
            (.authenticating, .failed),
            (.authenticating, .idle),
            (.replaying, .live),
            (.replaying, .recovering),
            (.replaying, .failed),
            (.replaying, .idle),
            (.live, .recovering),
            (.live, .failed),
            (.live, .idle),
            (.recovering, .connecting),
            (.recovering, .authenticating),
            (.recovering, .failed),
            (.recovering, .idle),
            (.failed, .connecting),
            (.failed, .idle):
            return true
        default:
            return false
        }
    }

    private func cancelPhaseTimers(for _: ConnectionLifecyclePhase) {
        connectTimeoutTask?.cancel()
        connectTimeoutTask = nil
        authTimeoutTask?.cancel()
        authTimeoutTask = nil
        replayTotalTimeoutTask?.cancel()
        replayTotalTimeoutTask = nil
        replayProgressTimeoutTask?.cancel()
        replayProgressTimeoutTask = nil
        historyResetAckTimeoutTask?.cancel()
        historyResetAckTimeoutTask = nil
    }

    private func cancelAllTimers() {
        reconnectTask?.cancel()
        reconnectTask = nil
        cancelPhaseTimers(for: phase)
    }

    private func emit(_ output: ConnectionLifecycleOutput) {
        continuation?.yield(output)
    }

    private func resetRecoveringState() {
        recoveringAttemptCount = 0
        reconnectBackoff = .seconds(1)
    }
}
