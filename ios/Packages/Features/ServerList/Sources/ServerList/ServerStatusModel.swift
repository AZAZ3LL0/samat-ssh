import AgentKit
import Foundation
import Observation
import Persistence
import SwiftData

/// Online or offline and a short CPU trend for every server in the list. Polls `GET /v1/metrics/host`
/// while the list is on screen: one socket per server would cost more than a coarse trend is worth.
@Observable @MainActor public final class ServerStatusModel {
    public struct Status: Equatable, Sendable {
        public var connection: ConnectionState = .connecting
        /// `cpu.usageRatio` of the latest answers, oldest first.
        public var cpu: [Double] = []

        public init(connection: ConnectionState = .connecting, cpu: [Double] = []) {
            self.connection = connection
            self.cpu = cpu
        }
    }

    /// About two minutes at the default interval.
    static let trendLength = 24

    private(set) var statuses: [UUID: Status] = [:]
    @ObservationIgnored private var clients: [UUID: any AgentClient] = [:]
    @ObservationIgnored private let makeClient: @MainActor (UUID) -> any AgentClient
    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let interval: Duration

    /// - Parameter makeClient: called once per server; the client is kept so its session is reused.
    public init(
        context: ModelContext, interval: Duration = .seconds(5),
        makeClient: @escaping @MainActor (UUID) -> any AgentClient
    ) {
        self.context = context
        self.interval = interval
        self.makeClient = makeClient
    }

    public func status(for id: UUID) -> Status {
        statuses[id] ?? Status()
    }

    /// Refreshes until the calling task is cancelled, as `.task` does when the list leaves the screen.
    public func run(_ ids: [UUID]) async {
        while !Task.isCancelled {
            await refresh(ids)
            try? await Task.sleep(for: interval)
        }
    }

    /// Asks every server once, all at the same time.
    func refresh(_ ids: [UUID]) async {
        let requests = ids.map { id in (id, client(for: id)) }
        await withTaskGroup(of: (UUID, Result<Double, AgentError>).self) { group in
            for (id, client) in requests {
                group.addTask {
                    do throws(AgentError) {
                        return (id, .success(try await client.hostMetrics().cpu.usageRatio))
                    } catch {
                        return (id, .failure(error))
                    }
                }
            }
            for await (id, result) in group {
                apply(result, to: id)
            }
        }
    }

    /// Forgets a deleted server and drops its client.
    public func remove(_ id: UUID) {
        statuses[id] = nil
        clients[id] = nil
    }

    private func client(for id: UUID) -> any AgentClient {
        if let client = clients[id] { return client }
        let client = makeClient(id)
        clients[id] = client
        return client
    }

    private func apply(_ result: Result<Double, AgentError>, to id: UUID) {
        var status = status(for: id)
        switch result {
        case .success(let cpu):
            status.connection = .connected
            status.cpu = Array((status.cpu + [cpu]).suffix(Self.trendLength))
            markSeen(id)
        case .failure:
            // The reason shows on the server screen; the list only needs reachable or not.
            status.connection = .offline
        }
        statuses[id] = status
    }

    private func markSeen(_ id: UUID) {
        let descriptor = FetchDescriptor<ServerRecord>(predicate: #Predicate { $0.id == id })
        guard let record = try? context.fetch(descriptor).first else { return }
        record.lastSeenAt = .now
        try? context.save()
    }
}
