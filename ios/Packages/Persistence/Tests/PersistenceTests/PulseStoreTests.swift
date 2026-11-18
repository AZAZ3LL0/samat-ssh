import Foundation
import SwiftData
import Testing

@testable import Persistence

@MainActor @Suite struct PulseStoreTests {
    @Test func storesServerWithDefaultAgentPort() throws {
        let context = try ModelContext(PulseStore.makeContainer(inMemory: true))
        let server = ServerRecord(name: "prod", host: "10.0.0.1", sortOrder: 0)
        context.insert(server)
        try context.save()

        let stored = try context.fetch(FetchDescriptor<ServerRecord>())
        #expect(stored.map(\.id) == [server.id])
        #expect(stored.first?.port == 7443)
        #expect(stored.first?.lastApiVersion == nil)
    }

    @Test func keepsOneSnapshotPerServer() throws {
        let context = try ModelContext(PulseStore.makeContainer(inMemory: true))
        let serverId = UUID()
        context.insert(CachedSnapshot(serverId: serverId, payload: Data("old".utf8), capturedAt: .distantPast))
        try context.save()
        context.insert(CachedSnapshot(serverId: serverId, payload: Data("new".utf8), capturedAt: .now))
        try context.save()

        let snapshots = try context.fetch(FetchDescriptor<CachedSnapshot>())
        #expect(snapshots.count == 1)
        #expect(snapshots.first?.payload == Data("new".utf8))
    }

    @Test func createsSettingsOnceWithDefaults() throws {
        let context = try ModelContext(PulseStore.makeContainer(inMemory: true))
        let first = try AppSettings.current(in: context)
        #expect(first.refreshPaused == false)
        #expect(first.demoModeEnabled == false)
        #expect(first.lastSelectedServerId == nil)

        first.demoModeEnabled = true
        let second = try AppSettings.current(in: context)
        #expect(second.demoModeEnabled)
        #expect(try context.fetchCount(FetchDescriptor<AppSettings>()) == 1)
    }

    @Test func schemaV1HoldsTheCacheModels() {
        #expect(SchemaV1.versionIdentifier == Schema.Version(1, 0, 0))
        #expect(PulseMigrationPlan.schemas.count == 1)
        let names = SchemaV1.models.map { String(describing: $0) }
        #expect(Set(names) == ["ServerRecord", "CachedSnapshot", "AppSettings"])
    }
}
