import AgentKit
import Foundation
import Observation

/// The host values the overview shows, mapped from the generated `HostMetrics`.
public struct OverviewSnapshot: Sendable, Equatable {
    /// Agent time of the sample.
    public let capturedAt: Date
    public let cpuRatio: Double
    public let cores: Int
    public let memoryUsedBytes: Int64
    public let memoryTotalBytes: Int64

    public init(_ metrics: HostMetrics) {
        capturedAt = metrics.ts
        cpuRatio = metrics.cpu.usageRatio
        cores = metrics.cpu.cores
        memoryUsedBytes = metrics.memory.usedBytes
        memoryTotalBytes = metrics.memory.totalBytes
    }

    /// Share of memory in use; `nil` instead of a division by zero when the total is unknown.
    public var memoryRatio: Double? {
        memoryTotalBytes > 0 ? Double(memoryUsedBytes) / Double(memoryTotalBytes) : nil
    }
}

/// Live CPU and memory of one server: a snapshot over REST for a fast first paint,
/// then `metrics.host` every second.
@Observable @MainActor public final class OverviewModel {
    public enum LoadState: Equatable {
        case loading
        case loaded(OverviewSnapshot)
        case failed(AgentError)
    }

    /// Samples kept for the sparklines: one minute at the agent's 1-second rate.
    public static let historyLimit = 60

    public private(set) var state: LoadState = .loading
    /// Usage ratios of the live samples, oldest first, at most `historyLimit`.
    public private(set) var cpuHistory: [Double] = []
    public private(set) var memoryHistory: [Double] = []
    public private(set) var connection: ConnectionState = .connecting
    /// Why the live stream stopped after data had arrived. The last values stay on
    /// screen as stale instead of being replaced by an error.
    public private(set) var streamError: AgentError?

    private let client: any AgentClient
    private var task: Task<Void, Never>?
    /// Device time of the last data, for `stale(since:)`: the agent's clock may be off.
    private var receivedAt: Date?

    public init(context: ServerContext) {
        client = context.client
    }

    /// Loads and follows the host until the calling task is cancelled or `stop()` runs.
    public func start() async {
        let task = launch()
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    /// Starts over after an error; the retry button of `ErrorBanner` calls it.
    public func retry() {
        launch()
    }

    @discardableResult private func launch() -> Task<Void, Never> {
        stop()
        let task = Task { await self.run() }
        self.task = task
        return task
    }

    private func run() async {
        connection = .connecting
        streamError = nil
        if case .failed = state { state = .loading }

        do throws(AgentError) {
            let snapshot = try await client.hostMetrics()
            // The snapshot paints the screen; the history holds live samples only, so a
            // sparkline never shows the same sample twice.
            state = .loaded(OverviewSnapshot(snapshot))
            receivedAt = .now
        } catch {
            fail(error)
            return
        }

        do {
            for try await event in client.subscribe(.metricsHost) {
                apply(OverviewSnapshot(event.payload))
            }
        } catch {
            guard !Task.isCancelled else { return }
            fail(error as? AgentError ?? .unreachable)
        }
    }

    private func apply(_ snapshot: OverviewSnapshot) {
        state = .loaded(snapshot)
        receivedAt = .now
        connection = .connected
        streamError = nil
        Self.append(snapshot.cpuRatio, to: &cpuHistory)
        if let ratio = snapshot.memoryRatio {
            Self.append(ratio, to: &memoryHistory)
        }
    }

    private func fail(_ error: AgentError) {
        if case .loaded = state {
            streamError = error
            connection = .stale(since: receivedAt ?? .now)
        } else {
            state = .failed(error)
            connection = .offline
        }
    }

    private static func append(_ value: Double, to history: inout [Double]) {
        history.append(value)
        if history.count > historyLimit {
            history.removeFirst(history.count - historyLimit)
        }
    }
}
