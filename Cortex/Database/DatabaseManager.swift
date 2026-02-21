// DatabaseManager.swift
// Cortex — Personal Knowledge Agent
//
// Single source of truth for SQLite access via GRDB.
// All targets (main app, Share Extension) use the shared App Group container path.
// Extensions write directly; main app reads and writes.

import Foundation
import GRDB

final class DatabaseManager {

    static let shared = DatabaseManager()

    private(set) var dbQueue: DatabaseQueue!

    // App Group container — shared between main app and extensions.
    // Must match the App Group entitlement in all targets: group.io.bdcllc.cortex
    static let appGroupIdentifier = "group.io.bdcllc.cortex"

    private init() {}

    func setup() throws {
        let url = try Self.databaseFileURL()
        var config = Configuration()
        config.prepareDatabase { db in
            // Enable WAL mode for concurrent reads from multiple processes
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
        }
        dbQueue = try DatabaseQueue(path: url.path, configuration: config)
        try migrator.migrate(dbQueue)
    }

    // MARK: - Path Resolution

    static func databaseFileURL() throws -> URL {
        // Prefer App Group container (shared across targets).
        // Falls back to Application Support for development/testing without entitlements.
        if let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) {
            return container.appendingPathComponent("cortex.sqlite")
        }

        // Fallback: app-private Application Support directory
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = appSupport.appendingPathComponent("Cortex", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("cortex.sqlite")
    }

    // MARK: - Migrations

    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_initial_schema") { db in

            // ── items ──────────────────────────────────────────────────────
            try db.create(table: "items") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("url", .text).notNull().unique()
                t.column("title", .text)
                t.column("source_platform", .text)          // twitter | reddit | youtube | web | manual
                t.column("content_type", .text)             // article | thread | video | paper | …
                t.column("raw_text", .text)
                t.column("summary", .text)
                t.column("key_insights_json", .text)        // JSON array of strings
                t.column("topics_json", .text)              // JSON array of strings
                t.column("fingerprint_json", .text)         // JSON object (domains, themes, entities)
                t.column("content_quality", .double)
                t.column("captured_at", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
                t.column("extracted_at", .datetime)
                t.column("enriched_at", .datetime)
                t.column("status", .text).notNull().defaults(to: "pending")
                t.column("read_by_user", .boolean).notNull().defaults(to: false)
                t.column("starred", .boolean).notNull().defaults(to: false)
            }

            // ── tags ───────────────────────────────────────────────────────
            try db.create(table: "tags") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull().unique()
                t.column("auto_generated", .boolean).notNull().defaults(to: true)
            }

            // ── item_tags (join) ───────────────────────────────────────────
            try db.create(table: "item_tags") { t in
                t.column("item_id", .integer).notNull()
                    .references("items", column: "id", onDelete: .cascade)
                t.column("tag_id", .integer).notNull()
                    .references("tags", column: "id", onDelete: .cascade)
                t.primaryKey(["item_id", "tag_id"])
            }

            // ── events (append-only truth layer) ───────────────────────────
            //
            // Every state change appends a row here. SQLite tables are a
            // materialized view of the event log. The event log is permanent.
            // idempotency_key UNIQUE ensures retries produce at most one event.
            try db.create(table: "events") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("event_type", .text).notNull()
                // item_captured | item_extracted | item_embedded | item_failed
                // connection_found | connection_dismissed
                // task_proposed | task_accepted | task_dismissed | task_completed
                // project_created | project_updated | synthesis_run_started | synthesis_run_completed
                // mcp_tool_called | context_logged | file_scanned | conversation_imported
                t.column("entity_type", .text)              // item | project | task | connection
                t.column("entity_id", .integer)
                t.column("payload_json", .text)             // full change payload
                t.column("source", .text).notNull()
                // safari_extension | share_sheet | mcp_call | menu_bar | scheduler | user
                t.column("idempotency_key", .text).unique()
                t.column("created_at", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
            }

            // ── indexes ────────────────────────────────────────────────────
            try db.create(
                index: "idx_items_status",
                on: "items", columns: ["status"])
            try db.create(
                index: "idx_items_source",
                on: "items", columns: ["source_platform"])
            try db.create(
                index: "idx_items_captured",
                on: "items", columns: ["captured_at"])
            try db.create(
                index: "idx_events_type",
                on: "events", columns: ["event_type"])
            try db.create(
                index: "idx_events_entity",
                on: "events", columns: ["entity_type", "entity_id"])
            try db.create(
                index: "idx_events_created",
                on: "events", columns: ["created_at"])
            try db.create(
                index: "idx_events_source",
                on: "events", columns: ["source"])
        }

        migrator.registerMigration("v2_add_priority") { db in
            try db.alter(table: "items") { t in
                t.add(column: "priority", .text).notNull().defaults(to: "normal")
            }
        }

        return migrator
    }
}
