import XCTest
@testable import NOOPExtras

/// A fake health server: answers ingest/photos/restore like server/health does.
final class FakeServer: @unchecked Sendable {
    var ingested: [String: [[String: Any]]] = [:]     // kind -> records as JSON
    var batches: [String: [Int]] = [:]                // kind -> batch sizes
    var photos: Set<String> = []
    var puts: [String] = []
    var badIds: Set<String> = []                      // ids the server rejects with 422
    var unreachable = false
    var unauthorized = false
    var snapshot: Data = Data(#"{"foods":[],"meals":[],"targets":[],"food_entries":[],"photos":[]}"#.utf8)
    lazy var transport: FakeTransport = {
        let t = FakeTransport()
        t.handler = { [unowned self] req in self.handle(req) }
        return t
    }()

    func handle(_ req: URLRequest) -> FakeTransport.Reply {
        if unreachable { return .error(URLError(.cannotFindHost)) }
        if unauthorized || req.value(forHTTPHeaderField: "Authorization") != "Bearer tok" {
            return .http(401, Data(#"{"detail":"invalid token"}"#.utf8))
        }
        let path = req.url!.path
        if path.hasPrefix("/api/v1/ingest/") {
            let kind = String(path.dropFirst("/api/v1/ingest/".count))
            let body = try! JSONSerialization.jsonObject(with: req.httpBody!) as! [String: Any]
            let recs = body["records"] as! [[String: Any]]
            if recs.count > 5000 { return .http(413, Data()) }
            if recs.contains(where: { badIds.contains($0["id"] as! String) }) {
                return .http(422, Data(#"{"detail":"record bad: at is not an ISO timestamp"}"#.utf8))
            }
            ingested[kind, default: []] += recs
            batches[kind, default: []].append(recs.count)
            return .http(200, Data(#"{"received":\#(recs.count),"applied":\#(recs.count)}"#.utf8))
        }
        if path.hasPrefix("/api/v1/photos/") {
            let id = String(path.dropFirst("/api/v1/photos/".count))
            if req.httpMethod == "HEAD" { return .http(photos.contains(id) ? 200 : 404, Data()) }
            if req.httpMethod == "PUT" {
                XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "image/jpeg")
                photos.insert(id); puts.append(id)
                return .http(200, Data(#"{"id":"\#(id)"}"#.utf8))
            }
        }
        if path == "/api/v1/restore/extras" { return .http(200, snapshot) }
        if path == "/api/v1/whoami" { return .http(200, Data(#"{"device":"iphone"}"#.utf8)) }
        return .http(404, Data())
    }
}

/// In-memory NOOP data for the engine (the real reader is tested against upstream's schema separately).
final class FakeNOOP: NOOPRecordSource, @unchecked Sendable {
    var byKind: [SyncKind: [SyncRecord]] = [:]
    var hr: [String: [Date: (fp: String, recs: [SyncRecord])]] = [:]   // device -> dayStart -> data
    var hrMinuteCalls = 0
    var unavailable: Set<SyncKind> = []
    func records(kind: SyncKind) throws -> [SyncRecord]? { unavailable.contains(kind) ? nil : (byKind[kind] ?? []) }
    func hrDevices() throws -> [String] { Array(hr.keys).sorted() }
    func hrFirstDay(deviceId: String) throws -> Date? { hr[deviceId]?.keys.min() }
    func hrFingerprint(deviceId: String, from: Date, to: Date) throws -> String? { hr[deviceId]?[from]?.fp }
    func hrMinutes(deviceId: String, from: Date, to: Date) throws -> [SyncRecord] {
        hrMinuteCalls += 1
        return hr[deviceId]?[from]?.recs ?? []
    }
}

final class SyncEngineTests: XCTestCase {
    var clock = Date(timeIntervalSince1970: 1_795_000_000)
    var cal: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Europe/Copenhagen")!; return c }()
    var store: ExtrasStore!
    var photos: PhotoStore!
    var server: FakeServer!
    var noop: FakeNOOP!
    var tmp: URL!

    override func setUpWithError() throws {
        store = try ExtrasStore(db: ExtrasDatabase.inMemory(), now: { [unowned self] in self.clock })
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        photos = try PhotoStore(directory: tmp, store: store)
        server = FakeServer()
        noop = FakeNOOP()
    }

    override func tearDown() { try? FileManager.default.removeItem(at: tmp) }

    func engine(token: String? = "tok") -> SyncEngine {
        let api = SyncAPI(config: SyncConfig(baseURL: URL(string: "https://health.example/api/v1")!, token: token),
                          transport: server.transport)
        return SyncEngine(store: store, api: api, reader: noop, photos: photos, calendar: cal,
                          now: { [unowned self] in self.clock })
    }

    func entry(_ kcal: Double) -> FoodEntry {
        FoodEntry.new(at: clock, meal: .lunch, method: .quick_add,
                      items: [EntryItem(name: "x", grams: nil, nutrients: Nutrients(kcal: kcal))])
    }

    func noopRecord(_ id: String, _ v: Double) -> SyncRecord {
        SyncRecord(id: id, updatedAt: clock, deleted: false,
                   data: ["day": .string("2026-11-17"), "recovery": .number(v)])
    }

    func test_sends_extras_and_marks_synced() async throws {
        try store.save(entry(500))
        try store.save(Targets(kcal: 2200, proteinG: 150, carbsG: 200, fatG: 70))
        let report = await engine().syncAll(force: true)
        XCTAssertNil(report.error)
        XCTAssertEqual(server.ingested["food_entries"]?.count, 1)
        XCTAssertEqual(server.ingested["targets"]?.first?["id"] as? String, "default")
        XCTAssertTrue(try store.dirty(kind: .food_entries).isEmpty)
        let second = await engine().syncAll(force: true)
        XCTAssertNil(second.error)
        XCTAssertEqual(server.ingested["food_entries"]?.count, 1)
    }

    func test_record_json_shape_matches_server() async throws {
        var e = entry(500); e.photoId = "p-1"; e.method = .photo_ai
        try store.save(e)
        _ = await engine().syncAll(force: true)
        let r = try XCTUnwrap(server.ingested["food_entries"]?.first)
        XCTAssertEqual(r["id"] as? String, e.id)
        XCTAssertNotNil(ExtrasCodec.parseWireDate(r["updated_at"] as! String))
        XCTAssertTrue((r["updated_at"] as! String).hasSuffix("Z"))
        XCTAssertEqual(r["deleted"] as? Bool, false)
        let data = r["data"] as! [String: Any]
        XCTAssertEqual(data["method"] as? String, "photo_ai")
        XCTAssertEqual(data["photo_id"] as? String, "p-1")
        XCTAssertNotNil(ExtrasCodec.parseWireDate(data["at"] as! String))
    }

    func test_batches_at_5000() async throws {
        noop.byKind[.daily_metrics] = (0..<12_001).map { noopRecord("dev|\($0)", 1) }
        let report = await engine().syncAll(force: true)
        XCTAssertNil(report.error)
        XCTAssertEqual(server.batches["daily_metrics"], [5000, 5000, 2001])
    }

    func test_bisects_422_and_quarantines_one() async throws {
        noop.byKind[.daily_metrics] = (0..<4000).map { noopRecord("dev|\($0)", 1) }
        server.badIds = ["dev|1234"]
        let report = await engine().syncAll(force: true)
        XCTAssertNil(report.error)
        XCTAssertEqual(server.ingested["daily_metrics"]?.count, 3999)
        XCTAssertEqual(report.quarantined, 1)
        XCTAssertEqual(try store.quarantined().map(\.id), ["dev|1234"])
        XCTAssertTrue(try store.quarantined().first!.error.contains("ISO"))
        // not resent forever: the next run sends nothing for an unchanged bad record
        let before = server.ingested["daily_metrics"]?.count
        _ = await engine().syncAll(force: true)
        XCTAssertEqual(server.ingested["daily_metrics"]?.count, before)
    }

    func test_unreachable_server_leaves_dirty() async throws {
        try store.save(entry(500))
        server.unreachable = true
        let report = await engine().syncAll(force: true)
        XCTAssertEqual(report.error, .unreachable)
        XCTAssertEqual(try store.dirty(kind: .food_entries).count, 1)
        server.unreachable = false
        _ = await engine().syncAll(force: true)
        XCTAssertEqual(server.ingested["food_entries"]?.count, 1)
    }

    func test_unauthorized_stops() async throws {
        try store.save(entry(500))
        noop.byKind[.daily_metrics] = [noopRecord("a", 1)]
        let report = await engine(token: "wrong").syncAll(force: true)
        XCTAssertEqual(report.error, .unauthorized)
        XCTAssertNil(server.ingested["daily_metrics"])
        XCTAssertEqual(try store.dirty(kind: .food_entries).count, 1)
    }

    func test_not_configured_without_token() async {
        let report = await engine(token: nil).syncAll(force: true)
        XCTAssertEqual(report.error, .notConfigured)
        XCTAssertTrue(server.transport.requests.isEmpty)
    }

    func test_photos_head_then_put_only_missing() async throws {
        let a = try photos.save(jpeg: sampleJPEG)
        let b = try photos.save(jpeg: sampleJPEG)
        server.photos = [a]
        _ = await engine().syncAll(force: true)
        XCTAssertEqual(server.puts, [b])
        XCTAssertEqual(try store.photosToUpload(), [])
        let heads = server.transport.requests.filter { $0.httpMethod == "HEAD" }.count
        XCTAssertEqual(heads, 2)
    }

    func test_ledger_sends_only_changes_and_tombstones_removed() async throws {
        noop.byKind[.sleep_sessions] = [
            SyncRecord(id: "d|1", updatedAt: clock, deleted: false, data: ["start_at": .string("2026-11-16T22:00:00Z"), "end_at": .string("2026-11-17T06:00:00Z")]),
            SyncRecord(id: "d|2", updatedAt: clock, deleted: false, data: ["start_at": .string("2026-11-17T22:00:00Z"), "end_at": .string("2026-11-18T06:00:00Z")]),
        ]
        _ = await engine().syncAll(force: true)
        XCTAssertEqual(server.ingested["sleep_sessions"]?.count, 2)
        // unchanged -> nothing; one changed + one removed -> 1 update + 1 tombstone carrying its last data
        clock += 600
        noop.byKind[.sleep_sessions] = [SyncRecord(id: "d|1", updatedAt: clock, deleted: false,
            data: ["start_at": .string("2026-11-16T22:30:00Z"), "end_at": .string("2026-11-17T06:00:00Z")])]
        _ = await engine().syncAll(force: true)
        let sent = server.ingested["sleep_sessions"]!.dropFirst(2)
        XCTAssertEqual(sent.count, 2)
        let tomb = try XCTUnwrap(sent.first { $0["id"] as? String == "d|2" })
        XCTAssertEqual(tomb["deleted"] as? Bool, true)
        XCTAssertEqual((tomb["data"] as? [String: Any])?["start_at"] as? String, "2026-11-17T22:00:00Z")
        _ = await engine().syncAll(force: true)
        XCTAssertEqual(server.ingested["sleep_sessions"]!.count, 4)
    }

    func test_hr_minute_by_day_with_fingerprints() async throws {
        let today = cal.startOfDay(for: clock)
        let old = cal.date(byAdding: .day, value: -40, to: today)!
        func recs(_ day: Date, _ n: Int) -> [SyncRecord] {
            (0..<n).map { SyncRecord(id: "w|\(Int(day.timeIntervalSince1970) + $0 * 60)", updatedAt: clock, deleted: false,
                                     data: ["at": .string(ExtrasCodec.wireDate(day.addingTimeInterval(Double($0) * 60))), "bpm": .number(60)]) }
        }
        noop.hr = ["w": [old: ("o1", recs(old, 1440)), today: ("t1", recs(today, 100))]]
        _ = await engine().syncAll(force: true)
        XCTAssertEqual(server.ingested["hr_minute"]?.count, 1540)
        // same fingerprints -> no re-read; a changed fingerprint for today -> today resent
        let calls = noop.hrMinuteCalls
        _ = await engine().syncAll(force: true)
        XCTAssertEqual(noop.hrMinuteCalls, calls)
        noop.hr["w"]![today] = ("t2", recs(today, 150))
        _ = await engine().syncAll(force: true)
        XCTAssertEqual(server.ingested["hr_minute"]?.count, 1690)
        // an OLD day whose data changed later is not re-scanned (outside the 14-day window)
        noop.hr["w"]![old] = ("o2", recs(old, 1440))
        _ = await engine().syncAll(force: true)
        XCTAssertEqual(server.ingested["hr_minute"]?.count, 1690)
    }

    func test_throttles_unless_forced() async throws {
        try store.save(entry(1))
        _ = await engine().syncAll()
        try store.save(entry(2))
        let r = await engine().syncAll()
        XCTAssertTrue(r.skipped)
        clock += 301
        let r2 = await engine().syncAll()
        XCTAssertFalse(r2.skipped)
        XCTAssertEqual(server.ingested["food_entries"]?.count, 2)
    }

    func test_restore_replaces_store() async throws {
        let food = Food(id: "f1", name: "Rugbrød", source: .custom, per100: Nutrients(kcal: 210))
        let snap: [String: Any] = [
            "foods": [["id": "f1", "updated_at": "2026-11-10T10:00:00Z", "data": try JSONSerialization.jsonObject(with: ExtrasCodec.wireEncoder.encode(food))]],
            "meals": [], "targets": [], "food_entries": [], "photos": [["id": "p1", "sha256": "x"]],
        ]
        server.snapshot = try JSONSerialization.data(withJSONObject: snap)
        let n = try await engine().restore(force: false)
        XCTAssertEqual(n, 1)
        XCTAssertEqual(try store.food(id: "f1")?.name, "Rugbrød")
    }

    func test_restore_refuses_over_unsynced_changes() async throws {
        try store.save(entry(500))
        do {
            _ = try await engine().restore(force: false)
            XCTFail("expected refusal")
        } catch let e as SyncError {
            XCTAssertEqual(e, .localChanges)
        }
        XCTAssertEqual(try store.dirty(kind: .food_entries).count, 1)
    }

    func test_whoami() async throws {
        let name = try await engine().api!.whoami()
        XCTAssertEqual(name, "iphone")
    }
}
