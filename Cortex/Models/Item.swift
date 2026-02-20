// Item.swift
// Cortex — Personal Knowledge Agent
//
// GRDB record for the `items` table.
// Status lifecycle: pending → extracting → indexed → enriched → connected
// Failures surface explicitly: partial | blocked | failed (never silent drops)

import Foundation
import GRDB

// MARK: - ItemStatus

enum ItemStatus: String, Codable, CaseIterable, DatabaseValueConvertible, Sendable {
    case pending    = "pending"
    case extracting = "extracting"
    case indexed    = "indexed"     // extracted, not yet embedded
    case enriched   = "enriched"    // fully processed, ready
    case connected  = "connected"   // linked to one or more projects
    case partial    = "partial"     // some content missing
    case blocked    = "blocked"     // site blocked scraping
    case failed     = "failed"      // hard failure

    var isTerminal: Bool {
        switch self {
        case .enriched, .connected, .partial, .blocked, .failed: return true
        default: return false
        }
    }

    var isProcessing: Bool {
        self == .pending || self == .extracting || self == .indexed
    }
}

// MARK: - SourcePlatform

enum SourcePlatform: String, Codable, CaseIterable, Sendable {
    case twitter = "twitter"
    case reddit  = "reddit"
    case youtube = "youtube"
    case web     = "web"
    case manual  = "manual"

    static func detect(from urlString: String) -> SourcePlatform {
        guard let host = URL(string: urlString)?.host?.lowercased() else { return .web }
        if host.contains("twitter.com") || host.contains("x.com") { return .twitter }
        if host.contains("reddit.com")                             { return .reddit }
        if host.contains("youtube.com") || host.contains("youtu.be") { return .youtube }
        return .web
    }
}

// MARK: - Item

struct Item: Identifiable, Equatable, Hashable, Sendable {
    var id: Int64?
    var url: String
    var title: String?
    var sourcePlatform: String?
    var contentType: String?
    var rawText: String?
    var summary: String?
    var keyInsightsJson: String?
    var topicsJson: String?
    var fingerprintJson: String?
    var contentQuality: Double?
    var capturedAt: Date
    var extractedAt: Date?
    var enrichedAt: Date?
    var status: ItemStatus
    var readByUser: Bool
    var starred: Bool
    
    // MARK: Hashable
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(url)
    }

    // MARK: Init

    init(url: String, title: String? = nil, sourcePlatform: SourcePlatform? = nil) {
        self.url = url
        self.title = title
        self.sourcePlatform = (sourcePlatform ?? SourcePlatform.detect(from: url)).rawValue
        self.capturedAt = Date()
        self.status = .pending
        self.readByUser = false
        self.starred = false
    }

    // MARK: Convenience

    var resolvedSourcePlatform: SourcePlatform {
        sourcePlatform.flatMap(SourcePlatform.init) ?? .web
    }

    var displayTitle: String {
        title ?? URL(string: url)?.host ?? url
    }

    var keyInsights: [String] {
        guard let json = keyInsightsJson,
              let data = json.data(using: .utf8),
              let array = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return array
    }

    var topics: [String] {
        guard let json = topicsJson,
              let data = json.data(using: .utf8),
              let array = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return array
    }
}

// MARK: - GRDB Conformance

extension Item: FetchableRecord, MutablePersistableRecord {

    nonisolated static var databaseTableName: String { "items" }

    enum Columns {
        nonisolated static let id             = Column("id")
        nonisolated static let url            = Column("url")
        nonisolated static let title          = Column("title")
        nonisolated static let sourcePlatform = Column("source_platform")
        nonisolated static let contentType    = Column("content_type")
        nonisolated static let rawText        = Column("raw_text")
        nonisolated static let summary        = Column("summary")
        nonisolated static let keyInsightsJson = Column("key_insights_json")
        nonisolated static let topicsJson     = Column("topics_json")
        nonisolated static let fingerprintJson = Column("fingerprint_json")
        nonisolated static let contentQuality = Column("content_quality")
        nonisolated static let capturedAt     = Column("captured_at")
        nonisolated static let extractedAt    = Column("extracted_at")
        nonisolated static let enrichedAt     = Column("enriched_at")
        nonisolated static let status         = Column("status")
        nonisolated static let readByUser     = Column("read_by_user")
        nonisolated static let starred        = Column("starred")
    }

    nonisolated init(row: Row) throws {
        id = row["id"]
        url = row["url"]
        title = row["title"]
        sourcePlatform = row["source_platform"]
        contentType = row["content_type"]
        rawText = row["raw_text"]
        summary = row["summary"]
        keyInsightsJson = row["key_insights_json"]
        topicsJson = row["topics_json"]
        fingerprintJson = row["fingerprint_json"]
        contentQuality = row["content_quality"]
        capturedAt = row["captured_at"]
        extractedAt = row["extracted_at"]
        enrichedAt = row["enriched_at"]
        status = row["status"]
        readByUser = row["read_by_user"]
        starred = row["starred"]
    }

    func encode(to container: inout PersistenceContainer) throws {
        container["id"] = id
        container["url"] = url
        container["title"] = title
        container["source_platform"] = sourcePlatform
        container["content_type"] = contentType
        container["raw_text"] = rawText
        container["summary"] = summary
        container["key_insights_json"] = keyInsightsJson
        container["topics_json"] = topicsJson
        container["fingerprint_json"] = fingerprintJson
        container["content_quality"] = contentQuality
        container["captured_at"] = capturedAt
        container["extracted_at"] = extractedAt
        container["enriched_at"] = enrichedAt
        container["status"] = status
        container["read_by_user"] = readByUser
        container["starred"] = starred
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - Convenience Queries

extension Item {
    /// All items ordered newest-first
    nonisolated static var allByDate: QueryInterfaceRequest<Item> {
        Item.order(Column("captured_at").desc)
    }

    /// Unread items
    nonisolated static var unread: QueryInterfaceRequest<Item> {
        Item.filter(Column("read_by_user") == false)
            .order(Column("captured_at").desc)
    }

    /// Starred items
    nonisolated static var starred: QueryInterfaceRequest<Item> {
        Item.filter(Column("starred") == true)
            .order(Column("captured_at").desc)
    }
}

