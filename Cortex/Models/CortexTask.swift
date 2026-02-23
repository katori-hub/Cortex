// CortexTask.swift
// Cortex — Personal Knowledge Agent
//
// GRDB record for the `tasks` table.
// Named CortexTask to avoid collision with Swift's built-in Task type.

import Foundation
import GRDB

// MARK: - TaskStatus

enum TaskStatus: String, Codable, DatabaseValueConvertible, CaseIterable, Sendable {
    case proposed  = "proposed"
    case active    = "active"
    case completed = "completed"
    case dismissed = "dismissed"
}

// MARK: - CortexTask

struct CortexTask: Identifiable, Equatable, Sendable {
    var id: Int64?
    var title: String
    var notes: String?
    var sourceItemId: Int64?
    var status: TaskStatus
    var createdAt: Date
    var updatedAt: Date?

    init(title: String, notes: String? = nil, sourceItemId: Int64? = nil, status: TaskStatus = .active) {
        self.title        = title
        self.notes        = notes
        self.sourceItemId = sourceItemId
        self.status       = status
        self.createdAt    = Date()
        self.updatedAt    = nil
    }
}

// MARK: - GRDB Conformances

extension CortexTask: FetchableRecord, MutablePersistableRecord {

    nonisolated static var databaseTableName: String { "tasks" }

    enum Columns {
        nonisolated static let id           = Column("id")
        nonisolated static let title        = Column("title")
        nonisolated static let notes        = Column("notes")
        nonisolated static let sourceItemId = Column("source_item_id")
        nonisolated static let status       = Column("status")
        nonisolated static let createdAt    = Column("created_at")
        nonisolated static let updatedAt    = Column("updated_at")
    }

    nonisolated init(row: Row) throws {
        id           = row["id"]
        title        = row["title"]
        notes        = row["notes"]
        sourceItemId = row["source_item_id"]
        let statusRaw: String = row["status"] ?? "active"
        status       = TaskStatus(rawValue: statusRaw) ?? .active
        createdAt    = row["created_at"]
        updatedAt    = row["updated_at"]
    }

    func encode(to container: inout PersistenceContainer) throws {
        container["id"]             = id
        container["title"]          = title
        container["notes"]          = notes
        container["source_item_id"] = sourceItemId
        container["status"]         = status.rawValue
        container["created_at"]     = createdAt
        container["updated_at"]     = updatedAt
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    // Proposed + active tasks, newest first
    nonisolated static var pending: QueryInterfaceRequest<CortexTask> {
        let statuses = [TaskStatus.proposed.rawValue, TaskStatus.active.rawValue]
        return CortexTask
            .filter(statuses.contains(Columns.status))
            .order(Columns.createdAt.desc)
    }
}
