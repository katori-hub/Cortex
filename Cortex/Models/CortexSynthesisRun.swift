// CortexSynthesisRun.swift
// Cortex — Personal Knowledge Agent
//
// GRDB record for the `synthesis_runs` table.

import Foundation
import GRDB

struct CortexSynthesisRun: Identifiable, Equatable, Sendable {
    var id: Int64?
    var startedAt: Date
    var completedAt: Date?
    var itemCount: Int
    var themesJson: String?
    var insightsJson: String?
    var proposedTasksJson: String?
    var status: String   // "running" | "completed" | "failed"
    var errorMessage: String?

    init() {
        self.startedAt   = Date()
        self.itemCount   = 0
        self.status      = "running"
    }
}

extension CortexSynthesisRun: FetchableRecord, MutablePersistableRecord {

    nonisolated static var databaseTableName: String { "synthesis_runs" }

    enum Columns {
        nonisolated static let id                = Column("id")
        nonisolated static let startedAt         = Column("started_at")
        nonisolated static let completedAt       = Column("completed_at")
        nonisolated static let itemCount         = Column("item_count")
        nonisolated static let themesJson        = Column("themes_json")
        nonisolated static let insightsJson      = Column("insights_json")
        nonisolated static let proposedTasksJson = Column("proposed_tasks_json")
        nonisolated static let status            = Column("status")
        nonisolated static let errorMessage      = Column("error_message")
    }

    nonisolated init(row: Row) throws {
        id                = row["id"]
        startedAt         = row["started_at"]
        completedAt       = row["completed_at"]
        itemCount         = row["item_count"] ?? 0
        themesJson        = row["themes_json"]
        insightsJson      = row["insights_json"]
        proposedTasksJson = row["proposed_tasks_json"]
        status            = row["status"] ?? "running"
        errorMessage      = row["error_message"]
    }

    func encode(to container: inout PersistenceContainer) throws {
        container["id"]                  = id
        container["started_at"]          = startedAt
        container["completed_at"]        = completedAt
        container["item_count"]          = itemCount
        container["themes_json"]         = themesJson
        container["insights_json"]       = insightsJson
        container["proposed_tasks_json"] = proposedTasksJson
        container["status"]              = status
        container["error_message"]       = errorMessage
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    nonisolated static var latest: QueryInterfaceRequest<CortexSynthesisRun> {
        CortexSynthesisRun.order(Columns.startedAt.desc).limit(1)
    }
}
