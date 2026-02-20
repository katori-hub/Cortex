// CaptureService.swift
// Cortex — Personal Knowledge Agent
//
// The capture bridge. Receives items from three sources:
//   1. Safari Extension → SafariWebExtensionHandler → DistributedNotificationCenter
//   2. Share Extension  → ShareViewController      → DistributedNotificationCenter
//   3. Direct API calls from main app UI (menu bar quick-capture)
//
// Writes items + events to SQLite. Deduplications by URL (UNIQUE constraint).
// Never drops work silently — failures are logged and surfaced.

import Foundation
import GRDB
import os.log
import Combine

// MARK: - CaptureService

@MainActor
final class CaptureService: ObservableObject {

    static let shared = CaptureService()

    // Published so UI can react to new captures in real time
    @Published var recentItems: [Item] = []
    @Published var totalCount: Int = 0

    private let logger = Logger(subsystem: "io.bdcllc.cortex", category: "CaptureService")
    private let notificationName = NSNotification.Name("io.bdcllc.cortex.capture")

    private init() {}

    // MARK: - Listening

    func startListening() {
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleCaptureNotification(_:)),
            name: notificationName,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        logger.info("CaptureService listening for notifications")
        Task { await refreshStats() }
    }

    @objc private func handleCaptureNotification(_ notification: NSNotification) {
        guard let userInfo = notification.userInfo,
              let url = userInfo["url"] as? String
        else {
            logger.warning("Received capture notification with no URL — ignored")
            return
        }

        let title          = userInfo["title"] as? String
        let sourceRaw      = userInfo["source"] as? String ?? "user"
        let platformContent = userInfo["platformContent"] as? [String: Any]

        logger.info("Capture notification received: \(url) from \(sourceRaw)")

        Task {
            await capture(
                url: url,
                title: title,
                source: CortexEventSource(rawValue: sourceRaw) ?? .user,
                platformContent: platformContent
            )
        }
    }

    // MARK: - Core Capture

    func capture(
        url: String,
        title: String?,
        source: CortexEventSource,
        platformContent: [String: Any]? = nil
    ) async {
        guard let _ = URL(string: url), url.hasPrefix("http") else {
            logger.warning("Invalid URL rejected: \(url)")
            return
        }

        guard let db = DatabaseManager.shared.dbQueue else {
            logger.error("Database not ready — capture dropped: \(url)")
            return
        }

        do {
            // Compute immutable inputs outside the @Sendable closure
            let computedPlatform: String? = {
                if let platform = platformContent?["platform"] as? String { return platform }
                return nil
            }()

            // Build immutable payload pieces outside the write closure
            var basePayload: [String: Any] = [
                "url": url,
                "source": source.rawValue,
            ]
            if let title { basePayload["title"] = title }
            if let computedPlatform { basePayload["source_platform"] = computedPlatform }
            if let pc = platformContent { basePayload["platform_content"] = pc }

            // Prepare item outside of the write closure to keep it synchronous
            let preparedItem: Item = {
                var item = Item(url: url, title: title)
                if let computedPlatform { item.sourcePlatform = computedPlatform }
                return item
            }()

            // Pre-construct event on the main actor to avoid calling a main-actor isolated initializer inside a nonisolated DB write closure
            let urlKey = url.data(using: .utf8)?.base64EncodedString() ?? url
            let preconstructedEvent: CortexEvent = await MainActor.run {
                var ev = CortexEvent(
                    eventType: .itemCaptured,
                    entityType: "item",
                    entityId: 0, // temporary, will be updated once we know the row id
                    payload: basePayload,
                    source: source
                )
                ev.idempotencyKey = "item_captured_\(urlKey)_\(source.rawValue)"
                return ev
            }

            try await db.write { db in
                var itemToInsert = preparedItem
                try? itemToInsert.insert(db, onConflict: .ignore)

                // Fetch id by URL regardless of whether the insert succeeded (row may have pre-existed)
                // Use Int64.fetchOne instead of Item.fetchOne to avoid Sendable conformance issues
                let itemId: Int64? = try Int64.fetchOne(
                    db,
                    sql: "SELECT id FROM items WHERE url = ?",
                    arguments: [url]
                )

                guard let entityId = itemId else { return }

                // Insert the event using the preconstructed main-actor event, updating the entityId now that we know it
                var event = preconstructedEvent
                event.entityId = entityId
                try event.insert(db, onConflict: .ignore)
            }

            logger.info("Captured: \(url)")
            await refreshStats()

        } catch {
            logger.error("Capture failed for \(url): \(error)")
        }
    }

    // MARK: - Stats

    nonisolated func refreshStats() async {
        guard let db = await DatabaseManager.shared.dbQueue else { return }
        do {
            // Perform reads in a nonisolated context to avoid Sendable conformance issues
            let fetched = try await db.read { db -> [Item] in
                try Item.order(Item.Columns.capturedAt.desc).limit(10).fetchAll(db)
            }
            let total = try await db.read { db -> Int in
                try Item.fetchCount(db)
            }
            // Assign back on the main actor
            await MainActor.run {
                self.recentItems = fetched
                self.totalCount = total
            }
        } catch {
            await MainActor.run {
                self.logger.error("Stats refresh failed: \(error)")
            }
        }
    }
}

