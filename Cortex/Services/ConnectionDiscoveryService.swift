// ConnectionDiscoveryService.swift
// Cortex — Personal Knowledge Agent
//
// Discovers connections between items by comparing embedding vectors.
// Runs after each item is embedded. Threshold: 0.7 (tight — only real matches).
// Deduplicates in Swift before inserting — no unique constraint on the table.

import Foundation
import GRDB
import os.log

actor ConnectionDiscoveryService {

    static let shared = ConnectionDiscoveryService()

    private let logger = Logger(subsystem: "io.bdcllc.cortex", category: "ConnectionDiscovery")
    private let threshold: Float = 0.7

    private init() {}

    // MARK: - Discovery

    /// Compare `itemId`'s embedding against all others. Insert connections above threshold.
    func discoverConnections(for itemId: Int64) async {
        guard let dbQueue = DatabaseManager.shared.dbQueue else { return }

        // Step 1: Load own vector, all other vectors, and existing pairs — single read
        struct LoadResult {
            let ownData: Data
            let others: [(id: Int64, vector: Data)]
            let alreadyConnected: Set<Int64>
        }

        let loaded: LoadResult?
        do {
            loaded = try await dbQueue.read { db -> LoadResult? in
                // Own vector
                guard let ownRow = try Row.fetchOne(
                    db,
                    sql: "SELECT vector_blob FROM item_embeddings WHERE item_id = ?",
                    arguments: [itemId]
                ), let ownData = ownRow["vector_blob"] as? Data else {
                    return nil
                }

                // All other vectors
                let otherRows = try Row.fetchAll(
                    db,
                    sql: "SELECT item_id, vector_blob FROM item_embeddings WHERE item_id != ?",
                    arguments: [itemId]
                )
                let others: [(id: Int64, vector: Data)] = otherRows.compactMap { row in
                    guard let vec = row["vector_blob"] as? Data else { return nil }
                    return (id: row["item_id"] as Int64, vector: vec)
                }

                // Existing connections (either direction, any dismissed state) to skip
                let existing = try ItemConnection
                    .filter(Column("item_id_a") == itemId || Column("item_id_b") == itemId)
                    .fetchAll(db)
                let alreadyConnected = Set(existing.map {
                    $0.itemIdA == itemId ? $0.itemIdB : $0.itemIdA
                })

                return LoadResult(ownData: ownData, others: others, alreadyConnected: alreadyConnected)
            }
        } catch {
            logger.error("discoverConnections read failed: \(error)")
            return
        }

        guard let result = loaded, !result.others.isEmpty else { return }

        // Step 2: Compute similarities in memory (no DB involvement)
        let ownVector = await EmbeddingService.shared.vectorFromData(result.ownData)
        var candidates: [(otherId: Int64, score: Float)] = []

        for other in result.others {
            guard !result.alreadyConnected.contains(other.id) else { continue }
            let otherVector = await EmbeddingService.shared.vectorFromData(other.vector)
            let score = await EmbeddingService.shared.cosineSimilarity(ownVector, otherVector)
            if score >= threshold {
                candidates.append((otherId: other.id, score: score))
            }
        }

        guard !candidates.isEmpty else { return }
        logger.info("Found \(candidates.count) connection(s) for item \(itemId)")

        // Step 3: Write each connection + event (separate write per pair for safe error isolation)
        for (otherId, score) in candidates {
            let minId = min(itemId, otherId)
            let maxId = max(itemId, otherId)

            do {
                try await dbQueue.write { db in
                    var conn = ItemConnection(
                        itemIdA: minId,
                        itemIdB: maxId,
                        similarityScore: Double(score)
                    )
                    try conn.insert(db)

                    var event = CortexEvent(
                        eventType: .connectionFound,
                        entityType: "connection",
                        entityId: conn.id,
                        source: .orchestrator,
                        idempotencyKey: "connection_found_\(minId)_\(maxId)"
                    )
                    try event.insert(db, onConflict: .ignore)
                }
                logger.info("Connection inserted: \(minId) ↔ \(maxId), score: \(String(format: "%.3f", score))")
            } catch {
                // Race condition / retry — safe to skip, connection already exists
                logger.warning("Connection insert skipped (pair may already exist): \(error)")
            }
        }
    }

    // MARK: - Dismiss

    /// Mark a connection as dismissed and log the event. Called from UI.
    func dismissConnection(_ connectionId: Int64) async {
        guard let dbQueue = DatabaseManager.shared.dbQueue else { return }

        do {
            try await dbQueue.write { db in
                guard var connection = try ItemConnection.fetchOne(db, key: connectionId) else { return }
                connection.dismissed = true
                try connection.update(db)

                var event = CortexEvent(
                    eventType: .connectionDismissed,
                    entityType: "connection",
                    entityId: connectionId,
                    source: .user,
                    idempotencyKey: "connection_dismissed_\(connectionId)"
                )
                try event.insert(db, onConflict: .ignore)
            }
            logger.info("Connection dismissed: \(connectionId)")
        } catch {
            logger.error("dismissConnection failed: \(error)")
        }
    }
}
