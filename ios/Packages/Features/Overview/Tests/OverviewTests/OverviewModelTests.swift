import AgentKit
import Foundation
import Testing

@testable import Overview

/// Acceptance criteria of the overview (tech.md §11, §12): seed data on open, live
/// updates every second, a bounded history, every AgentKit error shown, a dropped
/// stream keeping the last values as stale, and retry reconnecting.
@MainActor @Suite struct OverviewModelTests {
    /// `fixtures/host_metrics/01.json` … `05.json`, the order the fake replays them in.
    private static let seedCPU = [0.18, 0.24, 0.41, 0.33, 0.21]

    private func model(_ client: any AgentClient) -> OverviewModel {
        OverviewModel(context: ServerContext(serverId: UUID(), client: client))
    }

    private func fake(_ mode: FakeAgentClient.Mode = .normal) -> FakeAgentClient {
        FakeAgentClient(mode: mode, interval: .milliseconds(5))
    }

    @Test func startsLoading() {
        let model = model(fake())
        #expect(model.state == .loading)
        #expect(model.connection == .connecting)
    }

    @Test func showsSeedSnapshot() async throws {
        let model = model(fake())
        model.retry()
        defer { model.stop() }
        try await until { if case .loaded = model.state { true } else { false } }

        guard case .loaded(let snapshot) = model.state else { return }
        #expect(snapshot.cpuRatio == 0.18)
        #expect(snapshot.cores == 4)
        #expect(snapshot.memoryUsedBytes == 5_476_083_302)
        #expect(snapshot.memoryTotalBytes == 8_589_934_592)
    }

    @Test func followsLiveEventsInOrder() async throws {
        let model = model(fake())
        model.retry()
        defer { model.stop() }
        try await until { model.cpuHistory.count >= 7 }

        #expect(Array(model.cpuHistory.prefix(7)) == Self.seedCPU + Self.seedCPU.prefix(2))
        #expect(model.connection == .connected)
        #expect(model.streamError == nil)
        guard case .loaded(let snapshot) = model.state else {
            Issue.record("state is \(model.state), want loaded")
            return
        }
        #expect(model.cpuHistory.contains(snapshot.cpuRatio))
        #expect(model.memoryHistory.allSatisfy { (0...1).contains($0) })
    }

    @Test func keepsOneMinuteOfHistory() async throws {
        let model = model(fake())
        model.retry()
        defer { model.stop() }
        try await until { model.cpuHistory.count == OverviewModel.historyLimit }
        let firstFull = model.cpuHistory
        try await until { model.cpuHistory != firstFull }

        #expect(model.cpuHistory.count == OverviewModel.historyLimit)
        #expect(model.memoryHistory.count == OverviewModel.historyLimit)
    }

    @Test(arguments: [
        AgentError.unreachable, .timeout, .unauthorized, .pinMismatch, .decoding,
        .incompatibleAgent(agent: 1, required: 2), .server(.upstreamUnavailable, requestId: "r1"),
    ])
    func showsWhyNothingLoaded(error: AgentError) async throws {
        let model = model(fake(.failing(error)))
        await model.start()

        #expect(model.state == .failed(error))
        #expect(model.connection == .offline)
        #expect(model.cpuHistory.isEmpty)
    }

    @Test func droppedStreamKeepsLastValuesAsStale() async throws {
        let model = model(fake(.dropWebSocket(after: 3)))
        await model.start()

        #expect(model.cpuHistory == Array(Self.seedCPU.prefix(3)))
        #expect(model.streamError == .unreachable)
        guard case .stale = model.connection else {
            Issue.record("connection is \(model.connection), want stale")
            return
        }
        guard case .loaded(let snapshot) = model.state else {
            Issue.record("state is \(model.state), want the last snapshot")
            return
        }
        #expect(snapshot.cpuRatio == Self.seedCPU[2])
    }

    @Test func retryResubscribesAfterDrop() async throws {
        let model = model(fake(.dropWebSocket(after: 3)))
        await model.start()
        #expect(model.streamError == .unreachable)

        model.retry()
        defer { model.stop() }
        // The new subscription delivers its own three events, appended to the same history.
        try await until { model.cpuHistory.count == 6 && model.streamError != nil }
        #expect(model.cpuHistory == Array(Self.seedCPU.prefix(3)) + Array(Self.seedCPU.prefix(3)))
    }

    @Test func retryRecoversFromFailedLoad() async throws {
        let client = FlakyClient(failures: 1)
        let model = model(client)
        await model.start()
        #expect(model.state == .failed(.timeout))

        model.retry()
        defer { model.stop() }
        try await until { model.connection == .connected }
        guard case .loaded = model.state else {
            Issue.record("state is \(model.state), want loaded after retry")
            return
        }
    }

    @Test func stopEndsUpdates() async throws {
        let model = model(fake())
        model.retry()
        try await until { model.cpuHistory.count >= 2 }
        model.stop()
        let stopped = model.cpuHistory.count
        try await Task.sleep(for: .milliseconds(50))

        #expect(model.cpuHistory.count == stopped)
    }

    @Test func cancellingStartEndsUpdates() async throws {
        let model = model(fake())
        let running = Task { await model.start() }
        try await until { model.cpuHistory.count >= 2 }
        running.cancel()
        await running.value
        let stopped = model.cpuHistory.count
        try await Task.sleep(for: .milliseconds(50))

        #expect(model.cpuHistory.count == stopped)
    }

    /// Generated inputs: the memory ratio stays within 0...1 whenever used ≤ total,
    /// and an unknown total yields `nil`, never a division by zero.
    @Test(arguments: Self.memoryCases)
    func memoryRatioStaysWithinBounds(used: Int64, total: Int64) {
        let ratio = OverviewSnapshot(Self.metrics(used: used, total: total)).memoryRatio
        if total == 0 {
            #expect(ratio == nil)
        } else {
            guard let ratio else {
                Issue.record("ratio is nil for a known total \(total)")
                return
            }
            #expect((0...1).contains(ratio))
            #expect(abs(ratio - Double(used) / Double(total)) < 1e-12)
        }
    }

    nonisolated private static let memoryCases: [(Int64, Int64)] = {
        var generator = SystemRandomNumberGenerator()
        let edges: [(Int64, Int64)] = [(0, 0), (0, 1), (1, 1), (Int64.max, Int64.max), (0, Int64.max)]
        let random = (0..<50).map { _ -> (Int64, Int64) in
            let total = Int64.random(in: 1...(1 << 50), using: &generator)
            return (Int64.random(in: 0...total, using: &generator), total)
        }
        return edges + random
    }()

    nonisolated private static func metrics(used: Int64, total: Int64) -> HostMetrics {
        HostMetrics(
            ts: .now,
            cpu: .init(usageRatio: 0.5, cores: 2),
            memory: .init(totalBytes: total, usedBytes: used, availableBytes: total - used)
        )
    }
}

/// Fails `info` and `hostMetrics` with `.timeout` for the first `failures` calls, then
/// answers like the demo agent.
private final class FlakyClient: AgentClient, @unchecked Sendable {  // guarded by `lock`
    private let lock = NSLock()
    private var remaining: Int
    private let healthy = FakeAgentClient(interval: .milliseconds(5))

    init(failures: Int) {
        remaining = failures
    }

    private func shouldFail() -> Bool {
        lock.withLock {
            defer { remaining -= 1 }
            return remaining > 0
        }
    }

    func info() async throws(AgentError) -> AgentInfo {
        if shouldFail() { throw .timeout }
        return try await healthy.info()
    }

    func hostMetrics() async throws(AgentError) -> HostMetrics {
        if shouldFail() { throw .timeout }
        return try await healthy.hostMetrics()
    }

    func subscribe<T: Decodable & Sendable>(_ topic: WsTopic<T>) -> AsyncThrowingStream<WsEvent<T>, any Error> {
        healthy.subscribe(topic)
    }
}

/// Polls `condition` on the main actor until it holds, failing after `timeout`. The bound
/// only catches a hang: a CI runner under load has run these tests 50 times slower than
/// a laptop, and a passing condition returns as soon as it holds.
@MainActor private func until(
    timeout: Duration = .seconds(60),
    _ condition: () -> Bool,
    sourceLocation: SourceLocation = #_sourceLocation
) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else {
            Issue.record("condition not met within \(timeout)", sourceLocation: sourceLocation)
            throw CancellationError()
        }
        try await Task.sleep(for: .milliseconds(2))
    }
}
