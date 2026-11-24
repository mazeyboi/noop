import CryptoKit
import Foundation
import GRDB

/// What the engine needs from NOOP's own database (implemented by `NOOPDataReader`).
public protocol NOOPRecordSource: Sendable {
    /// sleep_sessions, daily_metrics, workouts, noop_intake: every current record. nil = can't tell right
    /// now (database missing): never read as "everything was deleted".
    func records(kind: SyncKind) throws -> [SyncRecord]?
    func hrDevices() throws -> [String]
    func hrFirstDay(deviceId: String) throws -> Date?
    /// A cheap summary of one device-day of heart rate; nil when there's none.
    func hrFingerprint(deviceId: String, from: Date, to: Date) throws -> String?
    func hrMinutes(deviceId: String, from: Date, to: Date) throws -> [SyncRecord]
}

public struct SyncReport: Equatable, Sendable {
    public var sent: [SyncKind: Int] = [:]
    public var photos = 0
    public var quarantined = 0
    public var error: SyncError?
    public var skipped = false
    public var finishedAt: Date?
}

/// Phone -> health server, on the home network only. Opportunistic: when the server can't be reached it
/// stops quietly and marks nothing, so the next run sends the same records again (the server upserts).
public final class SyncEngine: @unchecked Sendable {
    public static let batchSize = 5000
    public static let minInterval: TimeInterval = 5 * 60
    /// Heart-rate days re-checked on every run (NOOP can backfill a few days of strap data late).
    public static let hrRecheckDays = 14
    /// First sync of a long history is spread over several runs.
    public static let maxHrDaysPerRun = 60
    public static let lastSuccessKey = "sync.lastSuccess"
    static let lastReportKey = "sync.lastReport"
    /// More rejected records than this in one send means the server rejects everything (an API change, a
    /// client bug): stop and mark nothing, rather than quarantining every record for good.
    static let maxQuarantinePerSend = 3

    let store: ExtrasStore
    public let api: SyncAPI?
    let reader: NOOPRecordSource?
    let photos: PhotoStore
    let calendar: Calendar
    let now: () -> Date
    private let lock = NSLock()
    private var running = false
    private var quarantinedThisSend: [(kind: SyncKind, id: String)] = []

    public init(store: ExtrasStore, api: SyncAPI?, reader: NOOPRecordSource?, photos: PhotoStore,
                calendar: Calendar = .current, now: @escaping () -> Date = Date.init) {
        self.store = store; self.api = api; self.reader = reader; self.photos = photos
        self.calendar = calendar; self.now = now
    }

    public var lastSuccess: Date? {
        (try? store.kv(Self.lastSuccessKey)).flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
    }

    public func syncAll(force: Bool = false) async -> SyncReport {
        var report = SyncReport()
        guard lock.withLock({ () -> Bool in if running { return false }; running = true; return true }) else {
            report.skipped = true; return report
        }
        defer { lock.withLock { running = false } }
        if !force, let last = lastSuccess, now().timeIntervalSince(last) < Self.minInterval {
            report.skipped = true; return report
        }
        guard let api, let token = api.config.token, !token.isEmpty else {
            report.error = .notConfigured; return report
        }
        do {
            for kind in SyncKind.extras {
                let dirty = try store.dirty(kind: kind)
                guard !dirty.isEmpty else { continue }
                let n = try await send(kind, dirty, api: api, report: &report)
                try store.markSynced(kind: kind, records: dirty)
                report.sent[kind] = n
            }
            report.photos = try await uploadPhotos(api: api)
            if let reader {
                for kind in SyncKind.noop where kind != .hr_minute {
                    guard let current = try reader.records(kind: kind) else { continue }
                    let n = try await syncLedgered(kind, current, api: api, report: &report)
                    if n > 0 { report.sent[kind] = n }
                }
                let hr = try await syncHeartRate(reader, api: api, report: &report)
                if hr > 0 { report.sent[.hr_minute] = hr }
            }
            report.finishedAt = now()
            try? store.setKV(Self.lastSuccessKey, String(now().timeIntervalSince1970))
        } catch let e as SyncError {
            report.error = e
        } catch {
            // a database error (most likely NOOP's schema changed under NOOPDataReader)
            report.error = .local(String(describing: error))
        }
        return report
    }

    /// Sends records in batches of 5000. A 422 batch is split in halves until the bad record is alone;
    /// that one is quarantined and the rest go through. Other errors abort the run.
    private func send(_ kind: SyncKind, _ records: [SyncRecord], api: SyncAPI, report: inout SyncReport) async throws -> Int {
        var accepted = 0
        var start = 0
        quarantinedThisSend = []
        while start < records.count {
            let chunk = Array(records[start..<min(start + Self.batchSize, records.count)])
            accepted += try await sendChunk(kind, chunk, api: api, report: &report)
            start += Self.batchSize
        }
        return accepted
    }

    private func sendChunk(_ kind: SyncKind, _ chunk: [SyncRecord], api: SyncAPI, report: inout SyncReport) async throws -> Int {
        do {
            try await api.ingest(kind: kind, records: chunk)
            return chunk.count
        } catch SyncError.rejected(let why) {
            if chunk.count == 1 {
                let payload = (try? String(decoding: ExtrasCodec.wireEncoder.encode(chunk[0]), as: UTF8.self)) ?? ""
                try store.quarantine(kind: kind, id: chunk[0].id, error: why, payload: payload)
                quarantinedThisSend.append((kind, chunk[0].id))
                if quarantinedThisSend.count > Self.maxQuarantinePerSend {
                    for q in quarantinedThisSend { try store.unquarantine(kind: q.kind, id: q.id) }
                    quarantinedThisSend = []
                    throw SyncError.rejected("the server rejected many \(kind.rawValue) records (\(why)); nothing was marked synced")
                }
                report.quarantined += 1
                return 0
            }
            let mid = chunk.count / 2
            let a = try await sendChunk(kind, Array(chunk[..<mid]), api: api, report: &report)
            let b = try await sendChunk(kind, Array(chunk[mid...]), api: api, report: &report)
            return a + b
        }
    }

    // MARK: NOOP records (content-hash ledger)

    static func hash(_ r: SyncRecord) -> String {
        let data = (try? ExtrasCodec.wireEncoder.encode(r.data)) ?? Data()
        return SHA256.hash(data: data + Data([r.deleted ? 1 : 0])).map { String(format: "%02x", $0) }.joined()
    }

    private func ledger(_ kind: String) throws -> [String: (hash: String, data: String?)] {
        try store.db.read { db in
            var out: [String: (String, String?)] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT id, hash, data FROM syncLedger WHERE kind = ?", arguments: [kind]) {
                out[row["id"]] = (row["hash"], row["data"])
            }
            return out
        }
    }

    private func writeLedger(_ kind: String, _ entries: [(id: String, hash: String, data: String?)], remove: [String] = []) throws {
        try store.db.write { db in
            for e in entries {
                try db.execute(sql: "INSERT OR REPLACE INTO syncLedger (kind, id, hash, data) VALUES (?, ?, ?, ?)",
                               arguments: [kind, e.id, e.hash, e.data])
            }
            for id in remove {
                try db.execute(sql: "DELETE FROM syncLedger WHERE kind = ? AND id = ?", arguments: [kind, id])
            }
        }
    }

    /// Sends the records whose content changed since last time, and tombstones for ones NOOP no longer has.
    private func syncLedgered(_ kind: SyncKind, _ current: [SyncRecord], api: SyncAPI, report: inout SyncReport) async throws -> Int {
        let known = try ledger(kind.rawValue)
        var toSend: [SyncRecord] = []
        var newEntries: [(id: String, hash: String, data: String?)] = []
        var seen = Set<String>()
        for var r in current {
            seen.insert(r.id)
            let h = Self.hash(r)
            guard known[r.id]?.hash != h else { continue }
            r.updatedAt = now()    // NOOP rows have no edit time; "now" makes a changed row win on the server
            toSend.append(r)
            newEntries.append((r.id, h, String(decoding: (try? ExtrasCodec.wireEncoder.encode(r.data)) ?? Data(), as: UTF8.self)))
        }
        var removed = known.keys.filter { !seen.contains($0) }.sorted()
        // NOOP keeps only 48 h of caffeine intakes: ageing out isn't a deletion. Forget them quietly.
        let aged = removed.filter { $0.hasPrefix("caffeine|") }
        removed.removeAll { $0.hasPrefix("caffeine|") }
        // Many rows vanishing at once is NOOP rewriting its tables, not the user deleting: no tombstones
        // this run (if they really are gone, the rows stay in the ledger and the server keeps them).
        if removed.count > 20 && removed.count * 4 > known.count { removed = [] }
        for id in removed {
            let data = known[id]?.data.flatMap { try? JSONDecoder().decode([String: JSONValue].self, from: Data($0.utf8)) } ?? [:]
            toSend.append(SyncRecord(id: id, updatedAt: now(), deleted: true, data: data))
        }
        guard !toSend.isEmpty else {
            if !aged.isEmpty { try writeLedger(kind.rawValue, [], remove: aged) }
            return 0
        }
        let n = try await send(kind, toSend, api: api, report: &report)
        try writeLedger(kind.rawValue, newEntries, remove: removed + aged)
        return n
    }

    // MARK: heart rate (per device-day fingerprints)

    static func dayKey(_ d: Date, _ cal: Calendar) -> String {
        let c = cal.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    private func syncHeartRate(_ reader: NOOPRecordSource, api: SyncAPI, report: inout SyncReport) async throws -> Int {
        let known = try ledger("hr_day")
        let today = calendar.startOfDay(for: now())
        let recheckFrom = calendar.date(byAdding: .day, value: -Self.hrRecheckDays, to: today)!
        var batch: [SyncRecord] = []
        var batchDays: [(id: String, hash: String, data: String?)] = []
        var sent = 0
        var daysRead = 0

        func flush() async throws {
            guard !batch.isEmpty || !batchDays.isEmpty else { return }
            if !batch.isEmpty { sent += try await send(.hr_minute, batch, api: api, report: &report) }
            try writeLedger("hr_day", batchDays)
            batch.removeAll(); batchDays.removeAll()
        }

        for device in try reader.hrDevices() {
            guard let first = try reader.hrFirstDay(deviceId: device) else { continue }
            var day = calendar.startOfDay(for: first)
            while day <= today, daysRead < Self.maxHrDaysPerRun {
                let next = calendar.date(byAdding: .day, value: 1, to: day)!
                defer { day = next }
                let key = "\(device)|\(Self.dayKey(day, calendar))"
                if known[key] != nil && day < recheckFrom { continue }
                guard let fp = try reader.hrFingerprint(deviceId: device, from: day, to: next) else { continue }
                if known[key]?.hash == fp { continue }
                daysRead += 1
                let recs = try reader.hrMinutes(deviceId: device, from: day, to: next).map { r -> SyncRecord in
                    var r = r; r.updatedAt = now(); return r
                }
                if batch.count + recs.count > Self.batchSize { try await flush() }
                batch += recs
                batchDays.append((key, fp, nil))
            }
        }
        try await flush()
        return sent
    }

    // MARK: photos

    private func uploadPhotos(api: SyncAPI) async throws -> Int {
        var n = 0
        for id in try store.photosToUpload() {
            guard let jpeg = photos.data(id: id) else { try store.markPhotoUploaded(id: id); continue }
            let exists = try await api.photoExists(id: id)
            if !exists {
                try await api.putPhoto(id: id, jpeg: jpeg)
                n += 1
            }
            try store.markPhotoUploaded(id: id)
        }
        return n
    }

    // MARK: restore

    /// Rebuilds the food log from the server (new or reset phone). Refuses to overwrite unsynced local
    /// changes unless `force`.
    @discardableResult
    public func restore(force: Bool) async throws -> Int {
        guard let api else { throw SyncError.notConfigured }
        if !force, try store.hasUnsyncedChanges() { throw SyncError.localChanges }
        let snap = try await api.restore()
        try store.replaceAll(fromRestore: snap)
        for p in snap.photos { try? store.addPhotoRecord(id: p.id, uploaded: true) }
        return snap.foods.count + snap.meals.count + snap.targets.count + snap.entries.count
    }
}

extension ExtrasStore {
    func addPhotoRecord(id: String, uploaded: Bool) throws {
        try db.write { db in
            try db.execute(sql: "INSERT OR IGNORE INTO photo (id, fileName, uploaded, createdAt) VALUES (?, ?, ?, ?)",
                           arguments: [id, "\(id).jpg", uploaded, Date().timeIntervalSince1970])
        }
    }
}
