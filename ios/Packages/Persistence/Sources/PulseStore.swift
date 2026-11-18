import Foundation
import SwiftData

public enum PulseMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] { [SchemaV1.self] }
    public static var stages: [MigrationStage] { [] }
}

public enum PulseStore {
    /// The container for the app cache. `inMemory` serves tests, previews and demo mode.
    public static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        let schema = Schema(versionedSchema: SchemaV1.self)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory)
        return try ModelContainer(
            for: schema,
            migrationPlan: PulseMigrationPlan.self,
            configurations: [configuration]
        )
    }
}

extension AppSettings {
    /// The single settings row, created on first access.
    @MainActor public static func current(in context: ModelContext) throws -> AppSettings {
        if let settings = try context.fetch(FetchDescriptor<AppSettings>()).first {
            return settings
        }
        let settings = AppSettings()
        context.insert(settings)
        return settings
    }
}
