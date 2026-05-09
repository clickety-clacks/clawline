import Foundation
import Testing
@testable import Clawline

@MainActor
struct TerminalSessionConnectionPoolTests {
    @Test("T196: pool reuses a live terminal session across detach and reattach")
    func poolReusesLiveSessionAcrossViewDetach() async {
        let factory = MockTerminalSessionFactory()
        let pool = TerminalSessionConnectionPool(
            serviceFactory: { descriptor in
                factory.make(descriptor: descriptor)
            },
            idleDisconnectDelay: .seconds(5)
        )
        let descriptor = sampleDescriptor()

        let firstOwner = ConsumerOwner()
        let firstAttachment = pool.attach(
            owner: firstOwner,
            descriptor: descriptor,
            initialCols: 80,
            initialRows: 24,
            onStateChange: { firstOwner.states.append($0) },
            onOutput: { firstOwner.outputs.append($0) }
        )
        #expect(factory.makeCount == 1)

        guard let service = factory.lastService else {
            Issue.record("Expected pooled terminal service after first attach")
            return
        }
        service.emitOutput(Data("hello".utf8))
        service.emitState(.ready)
        await waitUntil { firstOwner.outputs == [Data("hello".utf8)] }
        await waitUntil { firstOwner.states.contains(.ready) }

        pool.detach(descriptor: descriptor, attachmentID: firstAttachment)

        let secondOwner = ConsumerOwner()
        _ = pool.attach(
            owner: secondOwner,
            descriptor: descriptor,
            initialCols: 80,
            initialRows: 24,
            onStateChange: { secondOwner.states.append($0) },
            onOutput: { secondOwner.outputs.append($0) }
        )
        await settle()

        #expect(factory.makeCount == 1)
        #expect(secondOwner.outputs == [Data("hello".utf8)])
        #expect(secondOwner.states == [.ready])
    }

    @Test("T196: latest attached consumer owns resize and input for a pooled terminal session")
    func latestAttachedConsumerOwnsInteractiveControl() async {
        let factory = MockTerminalSessionFactory()
        let pool = TerminalSessionConnectionPool(
            serviceFactory: { descriptor in
                factory.make(descriptor: descriptor)
            },
            idleDisconnectDelay: .seconds(5)
        )
        let descriptor = sampleDescriptor()

        let firstOwner = ConsumerOwner()
        let firstAttachment = pool.attach(
            owner: firstOwner,
            descriptor: descriptor,
            initialCols: 80,
            initialRows: 24,
            onStateChange: { _ in },
            onOutput: { _ in }
        )
        let secondOwner = ConsumerOwner()
        let secondAttachment = pool.attach(
            owner: secondOwner,
            descriptor: descriptor,
            initialCols: 120,
            initialRows: 40,
            onStateChange: { _ in },
            onOutput: { _ in }
        )

        guard let service = factory.lastService else {
            Issue.record("Expected pooled terminal service after attach")
            return
        }
        pool.resize(descriptor: descriptor, attachmentID: firstAttachment, cols: 90, rows: 30)
        pool.sendInput(descriptor: descriptor, attachmentID: firstAttachment, data: Data("first".utf8))
        pool.resize(descriptor: descriptor, attachmentID: secondAttachment, cols: 132, rows: 44)
        pool.sendInput(descriptor: descriptor, attachmentID: secondAttachment, data: Data("second".utf8))
        await settle()

        #expect(service.resizeCalls.count == 1)
        #expect(service.resizeCalls.first?.cols == 132)
        #expect(service.resizeCalls.first?.rows == 44)
        #expect(service.sentInputs == [Data("second".utf8)])
    }

    @Test("T196: stale service events are discarded after reconnect")
    func staleServiceEventsAreDiscardedAfterReconnect() async {
        let factory = MockTerminalSessionFactory()
        let pool = TerminalSessionConnectionPool(
            serviceFactory: { descriptor in
                factory.make(descriptor: descriptor)
            },
            idleDisconnectDelay: .seconds(5)
        )
        let descriptor = sampleDescriptor()
        let owner = ConsumerOwner()

        _ = pool.attach(
            owner: owner,
            descriptor: descriptor,
            initialCols: 80,
            initialRows: 24,
            onStateChange: { owner.states.append($0) },
            onOutput: { owner.outputs.append($0) }
        )
        await settle()

        guard factory.services.count == 1 else {
            Issue.record("Expected initial pooled terminal service")
            return
        }
        let firstService = factory.services[0]

        pool.requestReconnect(descriptor: descriptor, initialCols: 100, initialRows: 30)
        await settle()

        guard factory.services.count == 2 else {
            Issue.record("Expected replacement pooled terminal service after reconnect")
            return
        }
        let secondService = factory.services[1]

        firstService.emitOutput(Data("stale".utf8))
        firstService.emitState(.failed("stale"))
        secondService.emitOutput(Data("fresh".utf8))
        secondService.emitState(.ready)
        await waitUntil {
            combinedOutput(from: owner.outputs) == Data("fresh".utf8)
                && owner.states.contains(.ready)
                && !containsFailedState(owner.states)
        }

        #expect(combinedOutput(from: owner.outputs) == Data("fresh".utf8))
        #expect(!containsFailedState(owner.states))
    }

    @Test("T196: pool bounds buffered terminal output")
    func poolBoundsBufferedTerminalOutput() async {
        let factory = MockTerminalSessionFactory()
        let pool = TerminalSessionConnectionPool(
            serviceFactory: { descriptor in
                factory.make(descriptor: descriptor)
            },
            idleDisconnectDelay: .seconds(5),
            maxBufferedOutputBytes: 6
        )
        let descriptor = sampleDescriptor()

        let firstOwner = ConsumerOwner()
        let firstAttachment = pool.attach(
            owner: firstOwner,
            descriptor: descriptor,
            initialCols: 80,
            initialRows: 24,
            onStateChange: { _ in },
            onOutput: { firstOwner.outputs.append($0) }
        )
        guard let service = factory.lastService else {
            Issue.record("Expected pooled terminal service after attach")
            return
        }

        service.emitOutput(Data("ab".utf8))
        service.emitOutput(Data("cd".utf8))
        service.emitOutput(Data("ef".utf8))
        service.emitOutput(Data("gh".utf8))
        await waitUntil { firstOwner.outputs.count == 4 }

        pool.detach(descriptor: descriptor, attachmentID: firstAttachment)

        let secondOwner = ConsumerOwner()
        _ = pool.attach(
            owner: secondOwner,
            descriptor: descriptor,
            initialCols: 80,
            initialRows: 24,
            onStateChange: { _ in },
            onOutput: { secondOwner.outputs.append($0) }
        )
        await settle()

        #expect(combinedOutput(from: secondOwner.outputs) == Data("cdefgh".utf8))
    }

    @Test("T196: idle disconnect retires empty pooled entries")
    func idleDisconnectRetiresEmptyPooledEntries() async {
        let factory = MockTerminalSessionFactory()
        let pool = TerminalSessionConnectionPool(
            serviceFactory: { descriptor in
                factory.make(descriptor: descriptor)
            },
            idleDisconnectDelay: .milliseconds(10)
        )
        let descriptor = sampleDescriptor()

        let firstOwner = ConsumerOwner()
        let firstAttachment = pool.attach(
            owner: firstOwner,
            descriptor: descriptor,
            initialCols: 80,
            initialRows: 24,
            onStateChange: { _ in },
            onOutput: { _ in }
        )
        guard let firstService = factory.lastService else {
            Issue.record("Expected pooled terminal service after first attach")
            return
        }

        pool.detach(descriptor: descriptor, attachmentID: firstAttachment)
        await waitUntil { firstService.disconnectCount == 1 }

        let secondOwner = ConsumerOwner()
        _ = pool.attach(
            owner: secondOwner,
            descriptor: descriptor,
            initialCols: 100,
            initialRows: 30,
            onStateChange: { secondOwner.states.append($0) },
            onOutput: { _ in }
        )
        await waitUntil { factory.makeCount == 2 && secondOwner.states.contains(.connecting) }

        #expect(factory.makeCount == 2)
    }

    @Test("T196: dead consumers do not block idle cleanup")
    func deadConsumersDoNotBlockIdleCleanup() async {
        let factory = MockTerminalSessionFactory()
        let pool = TerminalSessionConnectionPool(
            serviceFactory: { descriptor in
                factory.make(descriptor: descriptor)
            },
            idleDisconnectDelay: .milliseconds(10)
        )
        let descriptor = sampleDescriptor()

        var owner: ConsumerOwner? = ConsumerOwner()
        guard owner != nil else {
            Issue.record("Expected test owner")
            return
        }
        if let owner {
            _ = pool.attach(
                owner: owner,
                descriptor: descriptor,
                initialCols: 80,
                initialRows: 24,
                onStateChange: { _ in },
                onOutput: { _ in }
            )
        }
        guard let firstService = factory.lastService else {
            Issue.record("Expected pooled terminal service after first attach")
            return
        }

        owner = nil
        firstService.emitOutput(Data("tick".utf8))
        await waitUntil { firstService.disconnectCount == 1 }

        let secondOwner = ConsumerOwner()
        _ = pool.attach(
            owner: secondOwner,
            descriptor: descriptor,
            initialCols: 80,
            initialRows: 24,
            onStateChange: { secondOwner.states.append($0) },
            onOutput: { _ in }
        )
        await waitUntil { factory.makeCount == 2 && secondOwner.states.contains(.connecting) }

        #expect(factory.makeCount == 2)
    }

    private func sampleDescriptor() -> TerminalSessionDescriptor {
        TerminalSessionDescriptor(
            version: 1,
            terminalSessionId: "ts_pool_test",
            title: "Terminal Pool Test",
            provider: .init(baseUrl: "https://example.com", wsPath: "/ws/terminal"),
            capabilities: .init(
                interactive: true,
                supportsBinaryFrames: true,
                supportsResize: true,
                supportsDetach: true
            ),
            auth: .init(mode: .chatToken, terminalAccessToken: nil),
            expiresAtMs: nil
        )
    }

    private func settle() async {
        await Task.yield()
        await Task.yield()
        await Task.yield()
    }

    private func waitUntil(_ predicate: @escaping @MainActor () -> Bool) async {
        for _ in 0..<50 {
            if predicate() { return }
            await settle()
            do {
                try await Task.sleep(for: .milliseconds(10))
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
    }

    private func combinedOutput(from chunks: [Data]) -> Data {
        chunks.reduce(into: Data()) { partial, chunk in
            partial.append(chunk)
        }
    }

    private func containsFailedState(_ states: [TerminalSessionService.State]) -> Bool {
        states.contains { state in
            if case .failed = state {
                return true
            }
            return false
        }
    }
}

@MainActor
private final class ConsumerOwner: NSObject {
    var states: [TerminalSessionService.State] = []
    var outputs: [Data] = []
}

@MainActor
private final class MockTerminalSessionFactory {
    private(set) var makeCount = 0
    private(set) var lastService: MockTerminalSessionController?
    private(set) var services: [MockTerminalSessionController] = []

    func make(descriptor: TerminalSessionDescriptor) -> MockTerminalSessionController {
        makeCount += 1
        let service = MockTerminalSessionController(descriptor: descriptor)
        lastService = service
        services.append(service)
        return service
    }
}

@MainActor
private final class MockTerminalSessionController: TerminalSessionControlling {
    let descriptor: TerminalSessionDescriptor
    private(set) var connectCalls: [(cols: Int, rows: Int, backfillLines: Int)] = []
    private(set) var disconnectCount = 0
    private(set) var sentInputs: [Data] = []
    private(set) var resizeCalls: [(cols: Int, rows: Int)] = []

    let output: AsyncStream<Data>
    private let outputContinuation: AsyncStream<Data>.Continuation

    let state: AsyncStream<TerminalSessionService.State>
    private let stateContinuation: AsyncStream<TerminalSessionService.State>.Continuation

    init(descriptor: TerminalSessionDescriptor) {
        self.descriptor = descriptor

        var outputContinuation: AsyncStream<Data>.Continuation!
        self.output = AsyncStream { continuation in
            outputContinuation = continuation
        }
        self.outputContinuation = outputContinuation

        var stateContinuation: AsyncStream<TerminalSessionService.State>.Continuation!
        self.state = AsyncStream { continuation in
            stateContinuation = continuation
        }
        self.stateContinuation = stateContinuation
    }

    func connect(initialCols: Int, initialRows: Int, backfillLines: Int) {
        connectCalls.append((cols: initialCols, rows: initialRows, backfillLines: backfillLines))
        stateContinuation.yield(.connecting)
    }

    func disconnect() {
        disconnectCount += 1
    }

    func sendInput(_ data: Data) {
        sentInputs.append(data)
    }

    func resize(cols: Int, rows: Int) {
        resizeCalls.append((cols: cols, rows: rows))
    }

    func emitOutput(_ data: Data) {
        outputContinuation.yield(data)
    }

    func emitState(_ state: TerminalSessionService.State) {
        stateContinuation.yield(state)
    }
}
