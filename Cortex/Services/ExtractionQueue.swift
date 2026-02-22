// ExtractionQueue.swift
// Cortex — Personal Knowledge Agent
//
// Batch processor for Phase 2 enrichment pipeline.
// Picks up items at status .indexed (TitleFetcher done),
// runs Gemini Flash extraction + NLEmbedding, writes results back.
// Respects rate limits (15 RPM free tier) and append-only event contract.

import Foundation
import GRDB
import os.log

actor ExtractionQueue {

    static let shared = ExtractionQueue()

    private let logger = Logger(subsystem: "io.bdcllc.cortex", category: "ExtractionQueue")
    private var isRunning = false

    private init() {}

    // MARK: - Public

    /// Start processing any items that need extraction.
    /// Safe to call multiple times — will no-op if already running.
    func processQueue() async {
        guard !isRunning else {
            logger.info("ExtractionQueue already running — skipping")
            return
        }
        isRunning = true
        defer { isRunning = false }

        logger.info("ExtractionQueue started")

        guard let db = DatabaseManager.shared.dbQueue else {
            logger.error("Database not ready")
            return
        }

        do {
            let pending = try await db.read { db -> [Item] in
                try Item
                    .filter(Item.Columns.status == ItemStatus.indexed.rawValue)
                    .order(Item.Columns.capturedAt.asc)
                    .limit(50)
                    .fetchAll(db)
            }

            guard !pending.isEmpty else {
                logger.info("No items pending extraction")
                return
            }

            logger.info("Found \(pending.count) items to process")

            for item in pending {
                await processItem(item, db: db)

                // Rate limit: ~4 seconds between calls = 15 RPM max
                try? await Task.sleep(for: .seconds(4))
            }

            logger.info("ExtractionQueue finished batch")
        } catch {
            logger.error("ExtractionQueue error: \(error)")
        }
    }

    // MARK: - Per-Item Processing

    private func processItem(_ item: Item, db: DatabaseQueue) async {
        guard let itemId = item.id else { return }

        logger.info("Processing item \(itemId): \(item.url)")

        // Step 1: Gemini extraction
        var extractionResult: ExtractionResult?
        do {
            extractionResult = try await GeminiService.shared.extract(
                title: item.title,
                url: item.url,
                rawText: item.rawText
            )
        } catch let error as GeminiError where error == .rateLimited {
            logger.warning("Rate limited — pausing queue")
            try? await Task.sleep(for: .seconds(60))
            return
        } catch let error as GeminiError where error == .noAPIKey {
            logger.error("No API key configured — stopping queue")
            return
        } catch {
            logger.warning("Gemini extraction failed for item \(itemId): \(error)")
            // Don't block the pipeline — mark as partial and continue
            await markStatus(itemId: itemId, status: .partial, db: db)
            await logEvent(itemId: itemId, type: .itemFailed, db: db)
            return
        }

        // Step 2: Update item with extraction results
        do {
            try await db.write { db in
                if var dbItem = try Item.fetchOne(db, key: itemId) {
                    if let result = extractionResult {
                        dbItem.summary = result.summary
                        dbItem.contentQuality = result.contentQuality

                        if !result.keyInsights.isEmpty,
                           let json = try? JSONEncoder().encode(result.keyInsights),
                           let str = String(data: json, encoding: .utf8) {
                            dbItem.keyInsightsJson = str
                        }
                        if !result.topics.isEmpty,
                           let json = try? JSONEncoder().encode(result.topics),
                           let str = String(data: json, encoding: .utf8) {
                            dbItem.topicsJson = str
                        }
                    }
                    dbItem.extractedAt = Date()
                    dbItem.status = .enriched
                    try dbItem.update(db)
                }
            }
        } catch {
            logger.error("DB update failed for item \(itemId): \(error)")
            return
        }

        await logEvent(itemId: itemId, type: .itemExtracted, db: db)

        // Step 3: Generate and store embedding
        let textForEmbedding = [item.title, extractionResult?.summary]
            .compactMap { $0 }
            .joined(separator: ". ")

        guard !textForEmbedding.isEmpty else { return }

        if let vectorData = await EmbeddingService.shared.embedAsData(text: textForEmbedding) {
            do {
                try await db.write { db in
                    try db.execute(
                        sql: """
                            INSERT OR REPLACE INTO item_embeddings (item_id, vector_blob, model_version, created_at)
                            VALUES (?, ?, 'NLEmbedding-en', CURRENT_TIMESTAMP)
                            """,
                        arguments: [itemId, vectorData]
                    )
                }
                await logEvent(itemId: itemId, type: .itemEmbedded, db: db)
                logger.info("Embedded item \(itemId)")
            } catch {
                logger.error("Embedding storage failed for item \(itemId): \(error)")
            }
        }
    }

    // MARK: - Helpers

    private func markStatus(itemId: Int64, status: ItemStatus, db: DatabaseQueue) async {
        do {
            try await db.write { db in
                if var item = try Item.fetchOne(db, key: itemId) {
                    item.status = status
                    try item.update(db)
                }
            }
        } catch {
            logger.error("Failed to mark item \(itemId) as \(status.rawValue): \(error)")
        }
    }

    private func logEvent(itemId: Int64, type: CortexEventType, db: DatabaseQueue) async {
        do {
            try await db.write { db in
                var event = CortexEvent(
                    eventType: type,
                    entityType: "item",
                    entityId: itemId,
                    source: .scheduler
                )
                try event.insert(db, onConflict: .ignore)
            }
        } catch {
            logger.error("Failed to log event \(type.rawValue) for item \(itemId): \(error)")
        }
    }
}

// MARK: - GeminiError Equatable

extension GeminiError: Equatable {
    static func == (lhs: GeminiError, rhs: GeminiError) -> Bool {
        lhs.localizedDescription == rhs.localizedDescription
    }
}
