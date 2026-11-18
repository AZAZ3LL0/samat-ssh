import Foundation
import SwiftData

/// The first version of the app cache. Models change only through a new
/// `VersionedSchema` and a stage in `PulseMigrationPlan`, never in place.
public enum SchemaV1: VersionedSchema {
    public static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

    public static var models: [any PersistentModel.Type] {
        [ServerRecord.self, CachedSnapshot.self, AppSettings.self]
    }

    /// A paired server. Not part of the contract: the agent does not know the name it was added under.
    @Model public final class ServerRecord {
        @Attribute(.unique) public var id: UUID
        public var name: String
        public var host: String
        public var port: Int
        public var sortOrder: Int
        public var colorTag: String?
        public var sshHost: String?
        public var sshPort: Int?
        public var sshUser: String?
        public var lastSeenAt: Date?
        public var lastApiVersion: Int?
        public var createdAt: Date

        public init(
            id: UUID = UUID(),
            name: String,
            host: String,
            port: Int = 7443,
            sortOrder: Int,
            colorTag: String? = nil,
            sshHost: String? = nil,
            sshPort: Int? = nil,
            sshUser: String? = nil,
            lastSeenAt: Date? = nil,
            lastApiVersion: Int? = nil,
            createdAt: Date = .now
        ) {
            self.id = id
            self.name = name
            self.host = host
            self.port = port
            self.sortOrder = sortOrder
            self.colorTag = colorTag
            self.sshHost = sshHost
            self.sshPort = sshPort
            self.sshUser = sshUser
            self.lastSeenAt = lastSeenAt
            self.lastApiVersion = lastApiVersion
            self.createdAt = createdAt
        }
    }

    /// The last `HostMetrics` of a server, so its screen opens instantly before live data arrives.
    @Model public final class CachedSnapshot {
        @Attribute(.unique) public var serverId: UUID
        /// JSON of the generated `HostMetrics`; Persistence stays independent of the API types.
        public var payload: Data
        public var capturedAt: Date

        public init(serverId: UUID, payload: Data, capturedAt: Date) {
            self.serverId = serverId
            self.payload = payload
            self.capturedAt = capturedAt
        }
    }

    @Model public final class AppSettings {
        public var refreshPaused: Bool
        public var demoModeEnabled: Bool
        public var lastSelectedServerId: UUID?

        public init(refreshPaused: Bool = false, demoModeEnabled: Bool = false, lastSelectedServerId: UUID? = nil) {
            self.refreshPaused = refreshPaused
            self.demoModeEnabled = demoModeEnabled
            self.lastSelectedServerId = lastSelectedServerId
        }
    }
}

public typealias ServerRecord = SchemaV1.ServerRecord
public typealias CachedSnapshot = SchemaV1.CachedSnapshot
public typealias AppSettings = SchemaV1.AppSettings
