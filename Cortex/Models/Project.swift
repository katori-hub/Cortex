// Project.swift
// Cortex — Personal Knowledge Agent
//
// GRDB records for the `projects` and `project_items` tables.
// Projects are user-created groups of items. Phase 3B.

import Foundation
import GRDB

// MARK: - Project

struct Project: Identifiable, Equatable, Hashable, Sendable {
    var id: Int64?
    var name: String
    var createdAt: Date

    init(name: String) {
        self.name = name
        self.createdAt = Date()
    }
}

extension Project: FetchableRecord, MutablePersistableRecord {

    nonisolated static var databaseTableName: String { "projects" }

    enum Columns {
        nonisolated static let id        = Column("id")
        nonisolated static let name      = Column("name")
        nonisolated static let createdAt = Column("created_at")
    }

    nonisolated init(row: Row) throws {
        id        = row["id"]
        name      = row["name"]
        createdAt = row["created_at"]
    }

    func encode(to container: inout PersistenceContainer) throws {
        container["id"]         = id
        container["name"]       = name
        container["created_at"] = createdAt
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    nonisolated static var allByName: QueryInterfaceRequest<Project> {
        Project.order(Columns.name.asc)
    }
}

// MARK: - ProjectItem

struct ProjectItem: Equatable, Sendable {
    var projectId: Int64
    var itemId: Int64
    var addedAt: Date

    init(projectId: Int64, itemId: Int64) {
        self.projectId = projectId
        self.itemId    = itemId
        self.addedAt   = Date()
    }
}

extension ProjectItem: FetchableRecord, PersistableRecord {

    nonisolated static var databaseTableName: String { "project_items" }

    nonisolated init(row: Row) throws {
        projectId = row["project_id"]
        itemId    = row["item_id"]
        addedAt   = row["added_at"]
    }

    func encode(to container: inout PersistenceContainer) throws {
        container["project_id"] = projectId
        container["item_id"]    = itemId
        container["added_at"]   = addedAt
    }
}
