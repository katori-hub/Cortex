// Event.swift
// Cortex — Personal Knowledge Agent
//
// GRDB record for the `events` table — the append-only truth layer.
//
// Design rules:
//   1. Append-only. Events are never updated or deleted.
//   2. Idempotent. idempotency_key is UNIQUE — retries produce at most one event.
//   3. Derived state. SQLite tables (items, connections, tasks) are materialized
//      views of the event log. The event log is the canonical truth.

import Foundation
import GRDB

// MARK: - EventType

enum CortexEventType: String, Codable, DatabaseValueConvertible, Sendable {
    // Capture + Extraction
    case itemCaptured          = "item_captured"
    case itemExtracted         = "item_extracted"
    case itemEmbedded          = "item_embedded"
    case itemFailed            = "item_failed"

    // Connections (Phase 3+)
    case connectionFound       = "connection_found"
    case connectionDismissed   = "connection_dismissed"

    // Tasks (Phase 4+)
    case taskProposed          = "task_proposed"
    case taskAccepted          = "task_accepted"
    case taskDismissed         = "task_dismissed"
    case taskCompleted         = "task_completed"
    case taskStatusChanged     = "task_status_changed"

    // Projects (Phase 3+)
    case projectCreated        = "project_created"
    case projectUpdated        = "project_updated"
    case projectArchived       = "project_archived"

    // Synthesis (Phase 4+)
    case synthesisRunStarted   = "synthesis_run_started"
    case synthesisRunCompleted = "synthesis_run_completed"

    // MCP / Context (Phase 5+)
    case mcpToolCalled         = "mcp_tool_called"
    case contextLogged         = "context_logged"
    case decisionLogged        = "decision_logged"

    // Import (Phase 5+)
    case fileScanned           = "file_scanned"
    case conversationImported  = "conversation_imported"
}

// MARK: - EventSource

enum CortexEventSource: String, Codable, DatabaseValueConvertible, Sendable {
    case safariExtension = "safari_extension"
    case shareSheet      = "share_sheet"
    case menuBar         = "menu_bar"
    case mcpCall         = "mcp_call"
    case fileScanner     = "file_scanner"
    case scheduler       = "scheduler"
    case orchestrator    = "orchestrator"
    case user            = "user"
    case connector       = "connector"
    // Use a distinct case name and raw value to avoid symbol collisions with any Taskmaster types/modules elsewhere.
    case taskRunner      = "task_runner"
}

// MARK: - CortexEvent

struct CortexEvent: Sendable {
    var id: Int64?
    var eventType: String
    var entityType: String?
    var entityId: Int64?
    var payloadJson: String?
    var source: String
    var idempotencyKey: String?
    var createdAt: Date
    
    // MARK: Init (typed)

    init(
        eventType eventTypeEnum: CortexEventType,
        entityType entityTypeParam: String? = nil,
        entityId entityIdParam: Int64? = nil,
        payload payloadParam: [String: Any]? = nil,
        source sourceEnum: CortexEventSource,
        idempotencyKey idempotencyKeyParam: String? = nil
    ) {
        self.id = nil
        self.eventType = eventTypeEnum.rawValue
        self.entityType = entityTypeParam
        self.entityId = entityIdParam
        self.source = sourceEnum.rawValue
        self.createdAt = Date()

        if let payloadParam,
           let data = try? JSONSerialization.data(withJSONObject: payloadParam, options: [.sortedKeys]),
           let jsonString = String(data: data, encoding: .utf8) {
            self.payloadJson = jsonString
        } else {
            self.payloadJson = nil
        }

        // Auto-generate idempotency key if not provided.
        // Format ensures the same logical operation produces the same key.
        self.idempotencyKey = idempotencyKeyParam
            ?? "\(eventTypeEnum.rawValue)_\(entityTypeParam ?? "")_\(entityIdParam?.description ?? "0")_\(sourceEnum.rawValue)"
    }

    // MARK: Init (raw strings — for extension targets without EventType enum access)

    init(
        eventTypeRaw: String,
        entityType entityTypeParam: String? = nil,
        entityId entityIdParam: Int64? = nil,
        payload payloadParam: [String: Any]? = nil,
        sourceRaw: String,
        idempotencyKey idempotencyKeyParam: String? = nil
    ) {
        self.id = nil
        self.eventType = eventTypeRaw
        self.entityType = entityTypeParam
        self.entityId = entityIdParam
        self.source = sourceRaw
        self.createdAt = Date()

        if let payloadParam,
           let data = try? JSONSerialization.data(withJSONObject: payloadParam, options: [.sortedKeys]),
           let jsonString = String(data: data, encoding: .utf8) {
            self.payloadJson = jsonString
        } else {
            self.payloadJson = nil
        }

        self.idempotencyKey = idempotencyKeyParam
            ?? "\(eventTypeRaw)_\(entityTypeParam ?? "")_\(entityIdParam?.description ?? "0")_\(sourceRaw)"
    }
}

// MARK: - GRDB Conformance

extension CortexEvent: FetchableRecord, MutablePersistableRecord {
    
    static let databaseTableName = "events"
    
    init(row: Row) {
        id = row["id"]
        eventType = row["event_type"]
        entityType = row["entity_type"]
        entityId = row["entity_id"]
        payloadJson = row["payload_json"]
        source = row["source"]
        idempotencyKey = row["idempotency_key"]
        createdAt = row["created_at"]
    }
    
    func encode(to container: inout PersistenceContainer) {
        container["id"] = id
        container["event_type"] = eventType
        container["entity_type"] = entityType
        container["entity_id"] = entityId
        container["payload_json"] = payloadJson
        container["source"] = source
        container["idempotency_key"] = idempotencyKey
        container["created_at"] = createdAt
    }
    
    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}


