import Foundation

/// How fresh the data of a server is, as `ConnectionIndicator` shows it.
public enum ConnectionState: Sendable, Equatable {
    case connecting
    case connected
    case offline
    /// Showing cached data captured at `since` while live data is unavailable.
    case stale(since: Date)
}
