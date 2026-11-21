import Foundation
import GRDB

/// What `GET /api/v1/restore/extras` returns.
public struct RestoreSnapshot: Codable, Equatable, Sendable {
    public struct Photo: Codable, Equatable, Sendable { public var id: String; public var sha256: String }
    public var foods: [SyncRecord]
    public var meals: [SyncRecord]
    public var targets: [SyncRecord]
    public var entries: [SyncRecord]
    public var photos: [Photo]

    public init(foods: [SyncRecord], meals: [SyncRecord], targets: [SyncRecord], entries: [SyncRecord],
                photos: [Photo] = []) {
        self.foods = foods; self.meals = meals; self.targets = targets; self.entries = entries; self.photos = photos
    }

    enum CodingKeys: String, CodingKey { case foods, meals, targets, entries = "food_entries", photos }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        foods = try c.decodeIfPresent([SyncRecord].self, forKey: .foods) ?? []
        meals = try c.decodeIfPresent([SyncRecord].self, forKey: .meals) ?? []
        targets = try c.decodeIfPresent([SyncRecord].self, forKey: .targets) ?? []
        entries = try c.decodeIfPresent([SyncRecord].self, forKey: .entries) ?? []
        photos = try c.decodeIfPresent([Photo].self, forKey: .photos) ?? []
    }
}

public struct QuarantinedRecord: Equatable, Sendable {
    public var kind: String
    public var id: String
    public var error: String
    public var at: Date
}

public struct DayTotals: Equatable, Sendable {
    public var logged: Nutrients
    /// Entries not counted yet: photos waiting for (or failing) an estimate.
    public var pendingCount: Int

    public init(logged: Nutrients, pendingCount: Int) {
        self.logged = logged; self.pendingCount = pendingCount
    }
}

/// All reads and writes of the extras database.
public final class ExtrasStore: @unchecked Sendable {
    public let db: DatabaseQueue
    private let now: () -> Date

    public init(db: DatabaseQueue, now: @escaping () -> Date = Date.init) {
        self.db = db
        self.now = now
    }

    static func table(_ kind: SyncKind) -> String? {
        switch kind {
        case .foods: return "food"
        case .meals: return "savedMeal"
        case .targets: return "targets"
        case .food_entries: return "entry"
        default: return nil
        }
    }

    // MARK: generic row helpers

    private func encode<T: Encodable>(_ v: T) throws -> String {
        String(decoding: try ExtrasCodec.dbEncoder.encode(v), as: UTF8.self)
    }

    private func decode<T: Decodable>(_ t: T.Type, _ json: String) throws -> T {
        try ExtrasCodec.dbDecoder.decode(T.self, from: Data(json.utf8))
    }

    private func upsert(_ db: Database, table: String, id: String, json: String, updatedAt: Date, deleted: Bool,
                        dirty: Bool = true, extra: [String: DatabaseValueConvertible?] = [:]) throws {
        var cols = ["id", "json", "updatedAt", "deleted", "dirty"]
        var vals: [DatabaseValueConvertible?] = [id, json, updatedAt.timeIntervalSince1970, deleted, dirty]
        for (k, v) in extra.sorted(by: { $0.key < $1.key }) { cols.append(k); vals.append(v) }
        let placeholders = Array(repeating: "?", count: cols.count).joined(separator: ", ")
        let updates = cols.dropFirst().map { "\($0) = excluded.\($0)" }.joined(separator: ", ")
        try db.execute(sql: "INSERT INTO \(table) (\(cols.joined(separator: ", "))) VALUES (\(placeholders)) "
                         + "ON CONFLICT(id) DO UPDATE SET \(updates)",
                       arguments: StatementArguments(vals))
    }

    // MARK: foods

    public func save(_ food: Food) throws {
        var f = food
        f.updatedAt = now()
        try db.write { db in
            let last = try Double.fetchOne(db, sql: "SELECT lastUsedAt FROM food WHERE id = ?", arguments: [f.id])
            try upsert(db, table: "food", id: f.id, json: encode(f), updatedAt: f.updatedAt, deleted: f.deleted,
                       extra: ["barcode": f.barcode, "favourite": f.favourite, "lastUsedAt": last])
        }
    }

    public func food(id: String) throws -> Food? {
        try db.read { db in
            try String.fetchOne(db, sql: "SELECT json FROM food WHERE id = ? AND NOT deleted", arguments: [id])
                .map { try decode(Food.self, $0) }
        }
    }

    public func food(barcode: String) throws -> Food? {
        try db.read { db in
            try String.fetchOne(db, sql: "SELECT json FROM food WHERE barcode = ? AND NOT deleted ORDER BY updatedAt DESC",
                                arguments: [barcode]).map { try decode(Food.self, $0) }
        }
    }

    public func recentFoods(limit: Int) throws -> [Food] {
        try db.read { db in
            try String.fetchAll(db, sql: "SELECT json FROM food WHERE NOT deleted AND lastUsedAt IS NOT NULL "
                                       + "ORDER BY lastUsedAt DESC LIMIT ?", arguments: [limit])
                .map { try decode(Food.self, $0) }
        }
    }

    public func favourites() throws -> [Food] {
        try db.read { db in
            try String.fetchAll(db, sql: "SELECT json FROM food WHERE NOT deleted AND favourite ORDER BY json")
                .map { try decode(Food.self, $0) }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    public func setFavourite(foodId: String, _ fav: Bool) throws {
        guard var f = try food(id: foodId) else { return }
        f.favourite = fav
        try save(f)
    }

    // MARK: entries

    public func save(_ entry: FoodEntry) throws {
        var e = entry
        e.updatedAt = now()
        let usedAt = now().timeIntervalSince1970
        try db.write { db in
            try upsert(db, table: "entry", id: e.id, json: encode(e), updatedAt: e.updatedAt, deleted: e.deleted,
                       extra: ["at": e.at.timeIntervalSince1970, "status": e.status.rawValue])
            for foodId in Set(e.items.compactMap(\.foodId)) where !e.deleted {
                try db.execute(sql: "UPDATE food SET lastUsedAt = ? WHERE id = ?", arguments: [usedAt, foodId])
            }
        }
    }

    public func entry(id: String) throws -> FoodEntry? {
        try db.read { db in
            try String.fetchOne(db, sql: "SELECT json FROM entry WHERE id = ?", arguments: [id])
                .map { try decode(FoodEntry.self, $0) }
        }
    }

    public func deleteEntry(id: String) throws {
        guard var e = try entry(id: id) else { return }
        e.deleted = true
        try save(e)
    }

    public func entries(on day: Date, calendar: Calendar = .current) throws -> [FoodEntry] {
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        return try db.read { db in
            try String.fetchAll(db, sql: "SELECT json FROM entry WHERE NOT deleted AND at >= ? AND at < ? ORDER BY at",
                                arguments: [start.timeIntervalSince1970, end.timeIntervalSince1970])
                .map { try decode(FoodEntry.self, $0) }
        }
    }

    public func dayTotals(on day: Date, calendar: Calendar = .current) throws -> DayTotals {
        let all = try entries(on: day, calendar: calendar)
        let logged = all.filter { $0.status == .logged }
        return DayTotals(logged: logged.reduce(.zero) { $0 + $1.totals },
                         pendingCount: all.count - logged.count)
    }

    public func pendingEntries() throws -> [FoodEntry] {
        try db.read { db in
            try String.fetchAll(db, sql: "SELECT json FROM entry WHERE NOT deleted AND status = 'pending' ORDER BY at")
                .map { try decode(FoodEntry.self, $0) }
        }
    }

    /// Puts an AI estimate on an entry. If Oliver already edited it, his values stay and only the original
    /// estimate is recorded.
    @discardableResult
    public func applyEstimate(_ est: FoodEstimate, to entryId: String, provider: String, model: String) throws -> FoodEntry? {
        guard var e = try entry(id: entryId), !e.deleted else { return nil }
        if e.aiOriginal == nil { e.aiOriginal = est }
        e.aiProvider = e.aiProvider ?? provider
        e.aiModel = e.aiModel ?? model
        if !e.edited {
            e.items = est.items.map(\.entryItem)
            e.confidence = est.confidence
            e.note = est.note.isEmpty ? nil : est.note
            e.aiProvider = provider
            e.aiModel = model
        }
        e.status = .logged
        e.error = nil
        try save(e)
        return e
    }

    // MARK: saved meals

    public func save(_ meal: SavedMeal) throws {
        var m = meal
        m.updatedAt = now()
        try db.write { db in
            try upsert(db, table: "savedMeal", id: m.id, json: encode(m), updatedAt: m.updatedAt, deleted: m.deleted)
        }
    }

    public func savedMeals() throws -> [SavedMeal] {
        try db.read { db in
            try String.fetchAll(db, sql: "SELECT json FROM savedMeal WHERE NOT deleted").map { try decode(SavedMeal.self, $0) }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    @discardableResult
    public func logSavedMeal(_ meal: SavedMeal, at: Date, meal type: MealType) throws -> FoodEntry {
        let e = FoodEntry.new(at: at, meal: type, method: .search, items: meal.items)
        try save(e)
        return e
    }

    /// Copies one meal of a day (for example yesterday's breakfast) to `date`.
    @discardableResult
    public func copyMeal(from day: Date, meal: MealType, to date: Date, calendar: Calendar = .current) throws -> [FoodEntry] {
        let source = try entries(on: day, calendar: calendar).filter { $0.meal == meal && $0.status == .logged }
        return try source.map { old in
            var e = FoodEntry.new(at: date, meal: meal, method: old.method, items: old.items)
            e.photoId = nil
            try save(e)
            return e
        }
    }

    // MARK: targets

    public func targets() throws -> Targets? {
        try db.read { db in
            try String.fetchOne(db, sql: "SELECT json FROM targets WHERE id = 'default' AND NOT deleted")
                .map { try decode(Targets.self, $0) }
        }
    }

    public func save(_ targets: Targets) throws {
        var t = targets
        t.updatedAt = now()
        try db.write { db in
            try upsert(db, table: "targets", id: "default", json: encode(t), updatedAt: t.updatedAt, deleted: false)
        }
    }

    // MARK: sync bookkeeping

    /// Records changed since they were last accepted by the server.
    public func dirty(kind: SyncKind) throws -> [SyncRecord] {
        guard let table = Self.table(kind) else { return [] }
        let rows = try db.read { db in
            try Row.fetchAll(db, sql: "SELECT id, json, updatedAt, deleted FROM \(table) WHERE dirty ORDER BY updatedAt")
        }
        return try rows.map { row in
            let id: String = row["id"], json: String = row["json"]
            let updatedAt = Date(timeIntervalSince1970: row["updatedAt"])
            let deleted: Bool = row["deleted"]
            var data: [String: JSONValue]
            switch kind {
            case .foods: data = try ExtrasCodec.data(decode(Food.self, json))
            case .meals: data = try ExtrasCodec.data(decode(SavedMeal.self, json))
            case .targets: data = try ExtrasCodec.data(decode(Targets.self, json))
            default:
                let e = try decode(FoodEntry.self, json)
                data = try ExtrasCodec.data(e)
                data["photo_id"] = e.photoId.map(JSONValue.string) ?? .null
                data["totals"] = try .object(ExtrasCodec.data(e.totals))
            }
            return SyncRecord(id: id, updatedAt: updatedAt, deleted: deleted, data: data)
        }
    }

    /// Clears `dirty` for records the server accepted, unless they changed again after being sent.
    public func markSynced(kind: SyncKind, records: [SyncRecord]) throws {
        guard let table = Self.table(kind) else { return }
        try db.write { db in
            for r in records {
                try db.execute(sql: "UPDATE \(table) SET dirty = 0 WHERE id = ? AND updatedAt <= ?",
                               arguments: [r.id, r.updatedAt.timeIntervalSince1970])
            }
        }
    }

    public func quarantine(kind: SyncKind, id: String, error: String, payload: String) throws {
        try db.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO quarantine (kind, id, error, payload, at) VALUES (?, ?, ?, ?, ?)",
                           arguments: [kind.rawValue, id, error, payload, now().timeIntervalSince1970])
        }
    }

    public func quarantined() throws -> [QuarantinedRecord] {
        try db.read { db in
            try Row.fetchAll(db, sql: "SELECT kind, id, error, at FROM quarantine ORDER BY at DESC").map {
                QuarantinedRecord(kind: $0["kind"], id: $0["id"], error: $0["error"],
                                  at: Date(timeIntervalSince1970: $0["at"]))
            }
        }
    }

    public func clearQuarantine() throws {
        try db.write { try $0.execute(sql: "DELETE FROM quarantine") }
    }

    public func kv(_ key: String) throws -> String? {
        try db.read { try String.fetchOne($0, sql: "SELECT value FROM kv WHERE key = ?", arguments: [key]) }
    }

    public func setKV(_ key: String, _ value: String?) throws {
        try db.write { db in
            if let value {
                try db.execute(sql: "INSERT OR REPLACE INTO kv (key, value) VALUES (?, ?)", arguments: [key, value])
            } else {
                try db.execute(sql: "DELETE FROM kv WHERE key = ?", arguments: [key])
            }
        }
    }

    /// True if anything owned by extras hasn't reached the server yet.
    public func hasUnsyncedChanges() throws -> Bool {
        try SyncKind.extras.contains { try !dirty(kind: $0).isEmpty }
    }

    /// Rebuilds the owned tables from a server snapshot (new or reset phone). Restored rows are clean.
    public func replaceAll(fromRestore snap: RestoreSnapshot) throws {
        try db.write { db in
            for t in ["food", "entry", "savedMeal", "targets"] { try db.execute(sql: "DELETE FROM \(t)") }
            for r in snap.foods {
                var f = try ExtrasCodec.decode(Food.self, from: r.data)
                f.id = r.id; f.updatedAt = r.updatedAt
                try upsert(db, table: "food", id: f.id, json: encode(f), updatedAt: r.updatedAt, deleted: false,
                           dirty: false, extra: ["barcode": f.barcode, "favourite": f.favourite, "lastUsedAt": nil])
            }
            for r in snap.meals {
                var m = try ExtrasCodec.decode(SavedMeal.self, from: r.data)
                m.id = r.id; m.updatedAt = r.updatedAt
                try upsert(db, table: "savedMeal", id: m.id, json: encode(m), updatedAt: r.updatedAt, deleted: false, dirty: false)
            }
            for r in snap.targets {
                var t = try ExtrasCodec.decode(Targets.self, from: r.data)
                t.updatedAt = r.updatedAt
                try upsert(db, table: "targets", id: "default", json: encode(t), updatedAt: r.updatedAt, deleted: false, dirty: false)
            }
            for r in snap.entries {
                var e = try ExtrasCodec.decode(FoodEntry.self, from: r.data)
                e.id = r.id; e.updatedAt = r.updatedAt
                try upsert(db, table: "entry", id: e.id, json: encode(e), updatedAt: r.updatedAt, deleted: false,
                           dirty: false, extra: ["at": e.at.timeIntervalSince1970, "status": e.status.rawValue])
            }
        }
    }
}
