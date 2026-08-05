import Foundation
import SwiftData

/// Version 1 of the persisted schema. New versions append here; `VerdantMigrationPlan`
/// stitches them together. Statics are `nonisolated` to satisfy the `VersionedSchema`
/// requirements under MainActor-default isolation.
nonisolated enum SchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version {
        Schema.Version(1, 0, 0)
    }

    static var models: [any PersistentModel.Type] {
        [
            InsightLog.self, CorrelationLog.self, MetricRollup.self, SyncAnchor.self,
            AgentState.self, ResearchJournalEntry.self
        ]
    }
}

/// Migration plan. Lightweight stages cover added properties and renames with no code; custom
/// stages run transforms. Only V1 exists today — per the owner, pre-release schema changes just
/// clobber the store (`AppContainer.makeOrRecreate` rebuilds the derived cache on open failure).
nonisolated enum VerdantMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [SchemaV1.self]
    }

    static var stages: [MigrationStage] {
        []
    }
}
