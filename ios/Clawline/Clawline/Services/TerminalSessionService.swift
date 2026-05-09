//
//  TerminalSessionService.swift
//  Clawline
//
//  Created by Codex on 2/7/26.
//

import Foundation
import OSLog

@MainActor
final class TerminalSessionService {
    enum State: Equatable {
        case disconnected
        case connecting
        case ready
        case exited(code: Int?)
        case failed(String)
    }

    private let logger = Logger(subsystem: "co.clicketyclacks.Clawline", category: "TerminalSession")
    private let descriptor: TerminalSessionDescriptor
    private let auth: any AuthManaging
    private let deviceId: any DeviceIdentifying

    // Use our own URLSession so we can set timeouts and headers consistently with the main chat socket.
    private let session: URLSession
    private let sessionDelegate: URLSessionDelegate
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var isReady: Bool = false
    private var pendingResize: (cols: Int, rows: Int)?
    private var enableMessagesTask: Task<Void, Never>?
    private var sawBackfillEnd: Bool = false
    private var backfillLinesRequested: Int = 0
    private var lastFailureMessage: String?

    private let outputContinuation: AsyncStream<Data>.Continuation
    let output: AsyncStream<Data>

    private let stateContinuation: AsyncStream<State>.Continuation
    let state: AsyncStream<State>

    init(descriptor: TerminalSessionDescriptor,
         auth: any AuthManaging,
         deviceId: any DeviceIdentifying) {
        self.descriptor = descriptor
        self.auth = auth
        self.deviceId = deviceId
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 360
        let delegate = ProviderWebSocketTLSSessionDelegate(policyProvider: { ProviderTLSSettingsStore.policy })
        self.sessionDelegate = delegate
        self.session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)

        var outCont: AsyncStream<Data>.Continuation!
        self.output = AsyncStream { cont in outCont = cont }
        self.outputContinuation = outCont

        var stCont: AsyncStream<State>.Continuation!
        self.state = AsyncStream { cont in stCont = cont }
        self.stateContinuation = stCont
    }

    @MainActor
    deinit {
        disconnect()
        outputContinuation.finish()
        stateContinuation.finish()
    }

    func connect(initialCols: Int, initialRows: Int, backfillLines: Int = 2000) {
        guard socket == nil else { return }
        isReady = false
        pendingResize = nil
        enableMessagesTask?.cancel()
        enableMessagesTask = nil
        sawBackfillEnd = false
        backfillLinesRequested = backfillLines
        lastFailureMessage = nil
        stateContinuation.yield(.connecting)

        guard let url = makeTerminalWebSocketURL() else {
            stateContinuation.yield(.failed("Missing provider URL"))
            return
        }

        let tokenPresent = resolveAuthToken() != nil
        logger.info("terminal_connect url=\(url.absoluteString, privacy: .public) terminalSessionId=\(self.descriptor.terminalSessionId, privacy: .public) deviceId=\(self.deviceId.deviceId, privacy: .public) tokenPresent=\(tokenPresent, privacy: .public)")

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        if request.value(forHTTPHeaderField: "Origin") == nil {
            request.setValue("https://clawline.app", forHTTPHeaderField: "Origin")
        }
        let task = session.webSocketTask(with: request)
        socket = task
        task.resume()

        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }

        pingTask = Task { [weak self] in
            await self?.pingLoop()
        }

        Task { [weak self] in
            await self?.sendAuth(
                initialCols: initialCols,
                initialRows: initialRows,
                backfillLines: backfillLines
            )
        }
    }

    func disconnect() {
        logger.info("terminal_disconnect terminalSessionId=\(self.descriptor.terminalSessionId, privacy: .public)")
        teardownSocket(yieldDisconnected: true)
    }

    private func teardownSocket(yieldDisconnected: Bool) {
        receiveTask?.cancel()
        receiveTask = nil
        pingTask?.cancel()
        pingTask = nil
        enableMessagesTask?.cancel()
        enableMessagesTask = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        isReady = false
        pendingResize = nil
        sawBackfillEnd = false
        backfillLinesRequested = 0
        if yieldDisconnected {
            stateContinuation.yield(.disconnected)
        }
    }

    func sendInput(_ data: Data) {
        guard isReady, let socket else {
            logger.warning("terminal_send_input_skipped: not ready or no socket")
            return
        }
        Task {
            do {
                try await socket.send(.data(data))
            } catch {
                logger.error("terminal_send_input_failed error=\(error.localizedDescription, privacy: .public)")
                await MainActor.run {
                    self.handleTransportFailure(error, context: "sendInput")
                }
            }
        }
    }

    func resize(cols: Int, rows: Int) {
        // Ignore or defer until the provider has accepted terminal_auth.
        pendingResize = (cols: cols, rows: rows)
        if !isReady {
            logger.debug("terminal_resize_deferred cols=\(cols, privacy: .public) rows=\(rows, privacy: .public)")
            return
        }
        sendControl(["type": "terminal_resize", "cols": cols, "rows": rows])
    }

    func detach() {
        sendControl(["type": "terminal_detach"])
    }

    func close() {
        sendControl(["type": "terminal_close"])
    }

    private func sendControl(_ dict: [String: Any]) {
        guard let socket else {
            logger.warning("terminal_send_control_skipped: no socket")
            return
        }
        if let type = dict["type"] as? String {
            logger.debug("terminal_send_control type=\(type, privacy: .public) ready=\(self.isReady, privacy: .public)")
        }
        Task {
            do {
                let data = try JSONSerialization.data(withJSONObject: dict, options: [])
                let text = String(decoding: data, as: UTF8.self)
                try await socket.send(.string(text))
            } catch {
                logger.error("terminal_send_control_failed error=\(error.localizedDescription, privacy: .public)")
                await MainActor.run {
                    self.handleTransportFailure(error, context: "sendControl")
                }
            }
        }
    }

    private func makeTerminalWebSocketURL() -> URL? {
        // Treat the paired provider base URL as authoritative.
        // The descriptor-advertised URL is a fallback for legacy payloads.
        let base: URL? = {
            if let paired = ProviderBaseURLStore.baseURL {
                return paired
            }
            if let raw = descriptor.provider?.baseUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
               !raw.isEmpty,
               let parsed = URL(string: raw) {
                return parsed
            }
            return nil
        }()
        guard let base else { return nil }
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        let scheme = components.scheme?.lowercased()
        switch scheme {
        case "https", "wss":
            components.scheme = "wss"
        case "http":
            components.scheme = "ws"
        case "ws":
            components.scheme = "ws"
        default:
            components.scheme = "ws"
        }

        // v1: only allow the known terminal endpoint path. Ignore any untrusted descriptor override.
        let candidatePath = descriptor.provider?.wsPath?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let candidatePath, !candidatePath.isEmpty, candidatePath != "/ws/terminal" {
            logger.warning("terminal_ws_path_ignored path=\(candidatePath, privacy: .public)")
        }
        components.path = "/ws/terminal"
        return components.url
    }

    private func sendAuth(initialCols: Int, initialRows: Int, backfillLines: Int) async {
        guard let socket else { return }
        let terminalSessionId = descriptor.terminalSessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        if terminalSessionId.isEmpty {
            stateContinuation.yield(.failed("Invalid terminalSessionId"))
            teardownSocket(yieldDisconnected: false)
            return
        }
        guard let token = resolveAuthToken() else {
            logger.error("terminal_auth_missing_token terminalSessionId=\(self.descriptor.terminalSessionId, privacy: .public)")
            stateContinuation.yield(.failed("Missing auth token"))
            teardownSocket(yieldDisconnected: false)
            return
        }

        let authMode = resolveAuthMode()
        logger.debug("terminal_auth_send terminalSessionId=\(self.descriptor.terminalSessionId, privacy: .public) deviceId=\(self.deviceId.deviceId, privacy: .public) authMode=\(authMode, privacy: .public) cols=\(initialCols, privacy: .public) rows=\(initialRows, privacy: .public) backfillLines=\(backfillLines, privacy: .public)")
        let payload: [String: Any] = [
            "type": "terminal_auth",
            "protocolVersion": 1,
            "authMode": authMode,
            "authToken": token,
            "deviceId": deviceId.deviceId,
            "terminalSessionId": terminalSessionId,
            "backfillLines": backfillLines,
            "cols": initialCols,
            "rows": initialRows
        ]

        do {
            let data = try JSONSerialization.data(withJSONObject: payload, options: [])
            let text = String(decoding: data, as: UTF8.self)
            try await socket.send(.string(text))
            logger.debug("terminal_auth_sent terminalSessionId=\(self.descriptor.terminalSessionId, privacy: .public)")
        } catch {
            logger.error("terminal_auth_send_failed error=\(String(describing: error), privacy: .public)")
            stateContinuation.yield(.failed("Auth send failed"))
            teardownSocket(yieldDisconnected: false)
        }
    }

    private func resolveAuthMode() -> String {
        if descriptor.auth?.terminalAccessToken != nil {
            return "terminal_access_token"
        }
        return "chat_token"
    }

    private func resolveAuthToken() -> String? {
        if let terminalToken = descriptor.auth?.terminalAccessToken, !terminalToken.isEmpty {
            return terminalToken
        }
        return auth.token
    }

    private func receiveLoop() async {
        guard let socket else { return }
        while !Task.isCancelled {
            do {
                let message = try await socket.receive()
                switch message {
                case .data(let data):
                    logger.debug("terminal_data_rx bytes=\(data.count, privacy: .public)")
                    outputContinuation.yield(data)
                case .string(let text):
                    // Providers may send PTY output either as binary frames or as text frames.
                    // Prefer JSON control parsing; if it is not a control envelope, treat as output.
                    logger.debug("terminal_text_rx text_len=\(text.count, privacy: .public)")
                    if !handleControl(text) {
                        outputContinuation.yield(Data(text.utf8))
                    }
                @unknown default:
                    break
                }
            } catch {
                if Task.isCancelled { break }
                logger.error("terminal_receive_failed error=\(String(describing: error), privacy: .public)")
                handleTransportFailure(error, context: "receiveLoop")
                break
            }
        }
    }

    private func handleTransportFailure(_ error: Error, context: String) {
        let message = error.localizedDescription
        lastFailureMessage = message
        isReady = false
        enableMessagesTask?.cancel()
        enableMessagesTask = nil
        logger.warning(
            "terminal_transport_failure context=\(context, privacy: .public) message=\(message, privacy: .public)"
        )
        stateContinuation.yield(.failed(message))
        teardownSocket(yieldDisconnected: false)
    }

    @discardableResult
    private func handleControl(_ text: String) -> Bool {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else {
            return false
        }

        if type == "terminal_error" {
            let message = (obj["message"] as? String) ?? "Terminal error"
            logger.warning("terminal_control terminal_error message=\(message, privacy: .public)")
        } else {
            logger.debug("terminal_control type=\(type, privacy: .public)")
        }

        switch type {
        case "terminal_ready":
            stateContinuation.yield(.ready)
            if backfillLinesRequested == 0 {
                // No backfill, so we won't see terminal_backfill_end.
                scheduleEnableMessagesIfNeeded()
            }
        case "terminal_backfill_end":
            sawBackfillEnd = true
            scheduleEnableMessagesIfNeeded()
        case "terminal_exit":
            let code = obj["code"] as? Int
            stateContinuation.yield(.exited(code: code))
        case "terminal_data":
            // Some providers envelope output as JSON. Support both raw UTF-8 and base64 payloads.
            if let payload = obj["data"] as? String {
                if let decoded = Data(base64Encoded: payload) {
                    outputContinuation.yield(decoded)
                } else {
                    outputContinuation.yield(Data(payload.utf8))
                }
            }
        case "terminal_error":
            let message = (obj["message"] as? String) ?? "Terminal error"
            isReady = false
            enableMessagesTask?.cancel()
            enableMessagesTask = nil
            stateContinuation.yield(.failed(message))
        case "terminal_closed":
            isReady = false
            enableMessagesTask?.cancel()
            enableMessagesTask = nil
            let rawReason =
                (obj["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ??
                (obj["reason"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let code = obj["code"] as? Int
            let reason: String = {
                if let rawReason, !rawReason.isEmpty {
                    return rawReason
                }
                if let code {
                    return "Terminal closed (code \(code))"
                }
                return "Terminal closed"
            }()
            stateContinuation.yield(.failed(reason))
            teardownSocket(yieldDisconnected: false)
        default:
            break
        }

        return true
    }

    private func scheduleEnableMessagesIfNeeded() {
        // Provider sends `terminal_ready` + (optional) backfill, but doesn't mark the socket
        // authenticated until after it spawns the tmux PTY. If we send resize/input too early,
        // the provider will reject with "Expected terminal_auth". Wait until backfill completes,
        // then add a small delay before sending any non-auth frames.
        guard enableMessagesTask == nil else { return }
        if !sawBackfillEnd {
            // If backfill was disabled, we never get `terminal_backfill_end`.
            // Delay a bit after ready (best-effort) by scheduling anyway.
        }
        enableMessagesTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch is CancellationError {
                return
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                guard !Task.isCancelled else { return }
                self.isReady = true
                self.logger.debug("terminal_messages_enabled terminalSessionId=\(self.descriptor.terminalSessionId, privacy: .public)")
                if let pendingResize = self.pendingResize {
                    self.sendControl([
                        "type": "terminal_resize",
                        "cols": pendingResize.cols,
                        "rows": pendingResize.rows
                    ])
                }
            }
        }
    }

    private func pingLoop() async {
        guard let socket else { return }
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(15))
                if Task.isCancelled { break }
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    socket.sendPing { error in
                        if let error {
                            cont.resume(throwing: error)
                        } else {
                            cont.resume()
                        }
                    }
                }
            } catch {
                if Task.isCancelled { break }
                logger.warning("terminal_ping_failed error=\(error.localizedDescription, privacy: .public)")
                handleTransportFailure(error, context: "pingLoop")
                break
            }
        }
    }


}
