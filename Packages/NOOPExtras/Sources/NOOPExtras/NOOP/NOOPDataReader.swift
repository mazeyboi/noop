import Foundation
import GRDB

/// Read-only access to NOOP's own data, for syncing it to the health server.
///
/// THE ONE FILE that knows NOOP's database layout (`Packages/WhoopStore/.../Database.swift`) and the
/// UserDefaults key of NOOP's caffeine log. Every other column is copied generically, so an upstream
/// column addition just shows up in the synced data; a rename or drop of a column used here fails
/// `NOOPDataReaderTests` (which build their fixture with upstream's current migrator) in the fork's CI.
/// Opens the database read-only and never writes to it.
public final class NOOPDataReader: NOOPRecordSource, @unchecked Sendable {
    let databaseURL: URL
    let defaults: UserDefaults
    let calendar: Calendar
    private let lock = NSLock()
    private var queue: DatabaseQueue?

    /// Large per-epoch JSON blobs that stay on the phone.
    static let skippedColumns: Set<String> = ["motionJSON", "sleepStateJSON", "synced"]

    public init(databaseURL: URL, defaults: UserDefaults = .standard, calendar: Calendar = .current) {
        self.databaseURL = databaseURL; self.defaults = defaults; self.calendar = calendar
    }

    /// `Application Support/OpenWhoop/whoop.sqlite` (see upstream `StorePaths.defaultDatabasePath`).
    public static func defaultURL() -> URL? {
        try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
            .appendingPathComponent("OpenWhoop", isDirectory: true).appendingPathComponent("whoop.sqlite")
    }

    private func db() throws -> DatabaseQueue? {
        try lock.withLock {
            if let queue { return queue }
            guard FileManager.default.fileExists(atPath: databaseURL.path) else { return nil }
            var config = Configuration()
            config.readonly = true
            config.busyMode = .timeout(5)
            let q = try DatabaseQueue(path: databaseURL.path, configuration: config)
            queue = q
            return q
        }
    }

    private func read<T>(_ empty: T, _ body: (Database) throws -> T) throws -> T {
        guard let q = try db() else { return empty }
        return try q.read(body)
    }

    // MARK: generic row -> data

    static func json(_ v: DatabaseValue) -> JSONValue? {
        switch v.storage {
        case .null: return .null
        case .int64(let i): return .number(Double(i))
        case .double(let d): return .number(d)
        case .string(let s): return .string(s)
        case .blob: return nil
        }
    }

    static func parsedJSON(_ s: String?) -> JSONValue? {
        guard let s, let d = s.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: d)
    }

    static func data(from row: Row) -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        for (col, value) in row where !skippedColumns.contains(col) {
            if col.hasSuffix("JSON") {
                if let s = String.fromDatabaseValue(value), let parsed = parsedJSON(s) {
                    out[String(col.dropLast(4))] = parsed
                }
                continue
            }
            if let j = json(value) { out[col] = j }
        }
        return out
    }

    static func iso(_ ts: Int64) -> JSONValue { .string(ExtrasCodec.wireDate(Date(timeIntervalSince1970: TimeInterval(ts)))) }

    // MARK: NOOPRecordSource

    public func records(kind: SyncKind) throws -> [SyncRecord]? {
        // No database file (fresh install, reset, or upstream moved it): unknown, not "all deleted".
        guard try db() != nil else { return nil }
        let now = Date()
        switch kind {
        case .sleep_sessions:
            return try read([]) { db in
                try Row.fetchAll(db, sql: "SELECT * FROM sleepSession ORDER BY startTs").map { row in
                    let dev: String = row["deviceId"], start: Int64 = row["startTs"], end: Int64 = row["endTs"]
                    var d = Self.data(from: row)
                    d["start_at"] = Self.iso(start); d["end_at"] = Self.iso(end); d["device_id"] = .string(dev)
                    return SyncRecord(id: "\(dev)|\(start)", updatedAt: now, deleted: false, data: d)
                }
            }
        case .daily_metrics:
            return try read([]) { db in
                try Row.fetchAll(db, sql: "SELECT * FROM dailyMetric ORDER BY day").map { row in
                    let dev: String = row["deviceId"], day: String = row["day"]
                    var d = Self.data(from: row)
                    d["device_id"] = .string(dev)
                    return SyncRecord(id: "\(dev)|\(day)", updatedAt: now, deleted: false, data: d)
                }
            }
        case .workouts:
            return try read([]) { db in
                try Row.fetchAll(db, sql: "SELECT * FROM workout ORDER BY startTs").map { row in
                    let dev: String = row["deviceId"], start: Int64 = row["startTs"], end: Int64 = row["endTs"]
                    let sport: String = row["sport"]
                    var d = Self.data(from: row)
                    d["start_at"] = Self.iso(start); d["end_at"] = Self.iso(end); d["device_id"] = .string(dev)
                    return SyncRecord(id: "\(dev)|\(start)|\(sport)", updatedAt: now, deleted: false, data: d)
                }
            }
        case .noop_intake:
            return caffeine(now: now) + (try hydration(now: now))
        default:
            return []
        }
    }

    /// NOOP's caffeine log (UserDefaults `caffeine.intakes`, JSON of `CaffeineIntake`, dates as seconds
    /// since 2001 — JSONEncoder's default).
    private func caffeine(now: Date) -> [SyncRecord] {
        guard let data = defaults.data(forKey: "caffeine.intakes"),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return list.compactMap { item in
            guard let id = item["id"] as? String, let at = (item["at"] as? NSNumber)?.doubleValue else { return nil }
            let mg = (item["mg"] as? NSNumber).map { JSONValue.number($0.doubleValue) } ?? .null
            return SyncRecord(id: "caffeine|\(id)", updatedAt: now, deleted: false, data: [
                "kind": .string("caffeine"), "at": .string(ExtrasCodec.wireDate(Date(timeIntervalSinceReferenceDate: at))),
                "mg": mg, "source": .string(item["externalId"] is String ? "apple_health" : "noop"),
            ])
        }
    }

    /// Daily water totals NOOP keeps in metricSeries (logged in NOOP, and imported from Apple Health).
    private func hydration(now: Date) throws -> [SyncRecord] {
        try read([]) { db in
            try Row.fetchAll(db, sql: "SELECT deviceId, day, key, value FROM metricSeries "
                                    + "WHERE key IN ('hydration', 'hydrationImported') ORDER BY day").compactMap { row in
                let dev: String = row["deviceId"], day: String = row["day"], key: String = row["key"]
                let ml: Double = row["value"]
                guard let noon = self.localNoon(day) else { return nil }
                return SyncRecord(id: "hydration|\(dev)|\(day)|\(key)", updatedAt: now, deleted: false, data: [
                    "kind": .string("water"), "day": .string(day), "at": .string(ExtrasCodec.wireDate(noon)),
                    "ml": .number(ml), "source": .string(key == "hydrationImported" ? "apple_health" : "noop"),
                ])
            }
        }
    }

    func localNoon(_ day: String) -> Date? {
        let p = day.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2], hour: 12))
    }

    public func hrDevices() throws -> [String] {
        // skip-scan over the (deviceId, ts) primary key instead of a full DISTINCT scan
        try read([]) { db in
            try String.fetchAll(db, sql: """
                WITH RECURSIVE d(id) AS (
                  SELECT MIN(deviceId) FROM hrSample
                  UNION ALL
                  SELECT (SELECT MIN(deviceId) FROM hrSample WHERE deviceId > d.id) FROM d WHERE d.id IS NOT NULL
                ) SELECT id FROM d WHERE id IS NOT NULL
                """)
        }
    }

    public func hrFirstDay(deviceId: String) throws -> Date? {
        try read(nil) { db in
            try Int64.fetchOne(db, sql: "SELECT MIN(ts) FROM hrSample WHERE deviceId = ?", arguments: [deviceId])
                .map { Date(timeIntervalSince1970: TimeInterval($0)) }
        }
    }

    public func hrFingerprint(deviceId: String, from: Date, to: Date) throws -> String? {
        try read(nil) { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT COUNT(*) AS c, COALESCE(SUM(bpm), 0) AS s, COALESCE(MAX(ts), 0) AS m
                FROM hrSample WHERE deviceId = ? AND ts >= ? AND ts < ?
                """, arguments: [deviceId, Int64(from.timeIntervalSince1970), Int64(to.timeIntervalSince1970)]) else { return nil }
            let c: Int64 = row["c"], s: Int64 = row["s"], m: Int64 = row["m"]
            return c == 0 ? nil : "\(c):\(s):\(m)"
        }
    }

    public func hrMinutes(deviceId: String, from: Date, to: Date) throws -> [SyncRecord] {
        let now = Date()
        return try read([]) { db in
            try Row.fetchAll(db, sql: """
                SELECT (ts / 60) * 60 AS m, AVG(bpm) AS avg, MIN(bpm) AS lo, MAX(bpm) AS hi, COUNT(*) AS n
                FROM hrSample WHERE deviceId = ? AND ts >= ? AND ts < ? GROUP BY m ORDER BY m
                """, arguments: [deviceId, Int64(from.timeIntervalSince1970), Int64(to.timeIntervalSince1970)]).map { row in
                let m: Int64 = row["m"], avg: Double = row["avg"], lo: Int64 = row["lo"], hi: Int64 = row["hi"], n: Int64 = row["n"]
                return SyncRecord(id: "\(deviceId)|\(m)", updatedAt: now, deleted: false, data: [
                    "at": Self.iso(m), "bpm": .number((avg * 10).rounded() / 10), "min": .number(Double(lo)),
                    "max": .number(Double(hi)), "n": .number(Double(n)), "device_id": .string(deviceId),
                ])
            }
        }
    }
}
