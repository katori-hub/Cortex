import Foundation
import GRDB

struct ItemConnection: Identifiable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var itemIdA: Int64
    var itemIdB: Int64
    var similarityScore: Double
    var dismissed: Bool
    var discoveredAt: Date

    static let databaseTableName = "connections"

    enum Columns: String, ColumnExpression {
        case id
        case itemIdA = "item_id_a"
        case itemIdB = "item_id_b"
        case similarityScore = "similarity_score"
        case dismissed
        case discoveredAt = "discovered_at"
    }

    init(id: Int64? = nil, itemIdA: Int64, itemIdB: Int64, similarityScore: Double, dismissed: Bool = false, discoveredAt: Date = Date()) {
        self.id = id
        self.itemIdA = itemIdA
        self.itemIdB = itemIdB
        self.similarityScore = similarityScore
        self.dismissed = dismissed
        self.discoveredAt = discoveredAt
    }

    init(row: Row) throws {
        id = row[Columns.id]
        itemIdA = row[Columns.itemIdA]
        itemIdB = row[Columns.itemIdB]
        similarityScore = row[Columns.similarityScore]
        dismissed = row[Columns.dismissed]
        discoveredAt = row[Columns.discoveredAt]
    }

    func encode(to container: inout PersistenceContainer) throws {
        container[Columns.id] = id
        container[Columns.itemIdA] = itemIdA
        container[Columns.itemIdB] = itemIdB
        container[Columns.similarityScore] = similarityScore
        container[Columns.dismissed] = dismissed
        container[Columns.discoveredAt] = discoveredAt
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    static func active(for itemId: Int64) -> QueryInterfaceRequest<ItemConnection> {
        ItemConnection
            .filter((Column("item_id_a") == itemId || Column("item_id_b") == itemId)
                    && Column("dismissed") == false)
            .order(Column("similarity_score").desc)
    }
}
