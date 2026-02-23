// SynthesisService.swift
// Cortex — Personal Knowledge Agent
//
// Nightly synthesis pass: reads enriched items from the last 7 days,
// calls Gemini for themes + insights + task proposals, persists results.

import Foundation
import GRDB
import os.log

actor SynthesisService {

    static let shared = SynthesisService()

    private let logger = Logger(subsystem: "io.bdcllc.cortex", category: "SynthesisService")
    private let endpoint = "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent"
    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 90
        self.session = URLSession(configuration: config)
    }

    // MARK: - Public

    /// Run only if synthesis hasn't already completed today.
    func runSynthesisIfNeeded() async {
        guard let db = DatabaseManager.shared.dbQueue else { return }
        do {
            let last = try await db.read { db in try CortexSynthesisRun.latest.fetchOne(db) }
            if let last, last.status == "completed",
               Calendar.current.isDateInToday(last.startedAt) {
                logger.info("Synthesis already ran today — skipping.")
                return
            }
        } catch {
            logger.error("Synthesis guard check failed: \(error)")
        }
        await runSynthesis()
    }

    /// Run synthesis unconditionally.
    func runSynthesis() async {
        guard let db = DatabaseManager.shared.dbQueue else { return }
        let apiKey = UserDefaults.standard.string(forKey: "geminiAPIKey") ?? ""
        guard !apiKey.isEmpty else {
            logger.warning("Synthesis skipped: no Gemini API key configured.")
            return
        }

        // ── Step 1: Create "running" record ─────────────────────────────
        var runId: Int64?
        do {
            try await db.write { db in
                var run = CortexSynthesisRun()
                try run.insert(db)
                runId = run.id
                var event = CortexEvent(
                    eventType: .synthesisRunStarted,
                    entityType: "synthesis_run",
                    entityId: run.id,
                    source: .scheduler
                )
                try event.insert(db, onConflict: .ignore)
            }
        } catch {
            logger.error("Could not start synthesis run: \(error)")
            return
        }
        guard let runId else { return }

        // ── Step 2: Fetch enriched items from the last 7 days ───────────
        do {
            let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
            let items = try await db.read { db in
                try Item
                    .filter(Item.Columns.status == ItemStatus.enriched.rawValue &&
                            Item.Columns.capturedAt >= cutoff)
                    .order(Item.Columns.capturedAt.desc)
                    .limit(30)
                    .fetchAll(db)
            }

            guard items.count >= 2 else {
                logger.info("Synthesis: only \(items.count) enriched items — skipping Gemini call.")
                try await db.write { db in
                    try db.execute(
                        sql: "UPDATE synthesis_runs SET status='completed', completed_at=CURRENT_TIMESTAMP, item_count=? WHERE id=?",
                        arguments: [items.count, runId]
                    )
                }
                return
            }

            // ── Step 3: Call Gemini ──────────────────────────────────────
            let prompt = buildPrompt(items: items)
            let responseText = try await callGemini(prompt: prompt, apiKey: apiKey)
            let result = parseResponse(responseText)
            let itemCount = items.count

            // ── Step 4: Persist results + proposed tasks ─────────────────
            try await db.write { [result, runId, itemCount] db in
                try db.execute(
                    sql: """
                        UPDATE synthesis_runs
                        SET status='completed', completed_at=CURRENT_TIMESTAMP,
                            item_count=?, themes_json=?, insights_json=?, proposed_tasks_json=?
                        WHERE id=?
                        """,
                    arguments: [itemCount, result.themesJson, result.insightsJson, result.tasksJson, runId]
                )
                for title in result.proposedTasks {
                    var task = CortexTask(title: title, status: .proposed)
                    try task.insert(db)
                    var event = CortexEvent(
                        eventType: .taskProposed,
                        entityType: "task",
                        entityId: task.id,
                        source: .orchestrator,
                        idempotencyKey: "synthesis_\(runId)_\(UUID().uuidString)"
                    )
                    try event.insert(db, onConflict: .ignore)
                }
                var doneEvent = CortexEvent(
                    eventType: .synthesisRunCompleted,
                    entityType: "synthesis_run",
                    entityId: runId,
                    source: .scheduler
                )
                try doneEvent.insert(db, onConflict: .ignore)
            }

            logger.info("Synthesis complete: \(itemCount) items, \(result.proposedTasks.count) tasks proposed.")

        } catch {
            logger.error("Synthesis failed: \(error)")
            try? await db.write { db in
                try db.execute(
                    sql: "UPDATE synthesis_runs SET status='failed', error_message=?, completed_at=CURRENT_TIMESTAMP WHERE id=?",
                    arguments: [error.localizedDescription, runId]
                )
            }
        }
    }

    // MARK: - Prompt Building

    private func buildPrompt(items: [Item]) -> String {
        let itemList = items.enumerated().map { i, item in
            let desc = item.summary ?? item.title ?? item.url
            return "\(i + 1). \(desc.prefix(300))"
        }.joined(separator: "\n")

        return """
        You are Cortex, a personal knowledge synthesis engine.
        Below are \(items.count) items captured and enriched in the last 7 days.

        Items:
        \(itemList)

        Analyze these items and return ONLY valid JSON (no markdown fencing, no explanation):
        {
          "themes": ["cross-cutting theme 1", "theme 2"],
          "key_insights": ["non-obvious insight combining multiple items", "insight 2"],
          "proposed_tasks": ["concrete actionable task 1", "task 2"]
        }

        Rules:
        - themes: 2-4 cross-cutting themes present across multiple items
        - key_insights: 2-5 non-obvious insights from combining items (not just restating individual summaries)
        - proposed_tasks: 0-3 concrete actionable tasks suggested by patterns in the content; empty array if none are obvious
        - Be specific. Avoid generic advice.
        """
    }

    // MARK: - Response Parsing

    private struct SynthesisResult: Sendable {
        let themes: [String]
        let insights: [String]
        let proposedTasks: [String]

        var themesJson: String? {
            try? String(data: JSONSerialization.data(withJSONObject: themes), encoding: .utf8)
        }
        var insightsJson: String? {
            try? String(data: JSONSerialization.data(withJSONObject: insights), encoding: .utf8)
        }
        var tasksJson: String? {
            try? String(data: JSONSerialization.data(withJSONObject: proposedTasks), encoding: .utf8)
        }
    }

    private func parseResponse(_ text: String) -> SynthesisResult {
        let clean = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")

        guard let data = clean.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            logger.error("Synthesis: could not parse Gemini response.")
            return SynthesisResult(themes: [], insights: [], proposedTasks: [])
        }

        return SynthesisResult(
            themes:        json["themes"]         as? [String] ?? [],
            insights:      json["key_insights"]   as? [String] ?? [],
            proposedTasks: json["proposed_tasks"] as? [String] ?? []
        )
    }

    // MARK: - Gemini REST Call

    private func callGemini(prompt: String, apiKey: String) async throws -> String {
        guard var urlComponents = URLComponents(string: endpoint) else {
            throw URLError(.badURL)
        }
        urlComponents.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        guard let url = urlComponents.url else { throw URLError(.badURL) }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "contents": [["parts": [["text": prompt]]]],
            "generationConfig": ["temperature": 0.3, "maxOutputTokens": 1024]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let text = candidates.first?["content"] as? [String: Any],
              let parts = text["parts"] as? [[String: Any]],
              let result = parts.first?["text"] as? String
        else { throw URLError(.cannotParseResponse) }

        return result
    }
}
