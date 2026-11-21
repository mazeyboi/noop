import XCTest
@testable import NOOPExtras

/// Regression tests for the plan 3 final review findings.
final class ReviewFixTests: XCTestCase {
    var cal: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Europe/Copenhagen")!; return c }()
    func at(_ d: Int, _ h: Int, _ m: Int = 0) -> Date { cal.date(from: DateComponents(year: 2026, month: 11, day: d, hour: h, minute: m))! }

    // C1: numbers typed on a decimal pad must reach the model on every keystroke
    func test_number_input_parses_while_typing() {
        XCTAssertEqual(NumberInput.parse("250"), 250)
        XCTAssertEqual(NumberInput.parse("12,5"), 12.5)
        XCTAssertEqual(NumberInput.parse(" 7.25 "), 7.25)
        XCTAssertEqual(NumberInput.parse("0"), 0)
        XCTAssertNil(NumberInput.parse(""))
        XCTAssertNil(NumberInput.parse("abc"))
        XCTAssertNil(NumberInput.parse("-5"))
        XCTAssertEqual(NumberInput.text(250), "250")
        XCTAssertEqual(NumberInput.text(12.5), "12.5")
        XCTAssertEqual(NumberInput.text(0), "")
    }

    // I1: the food log follows "today" across midnight unless another day was picked
    func test_day_selection_rolls_forward_after_midnight() {
        var sel = DaySelection(now: at(20, 22), calendar: cal)
        sel.refresh(now: at(21, 7), calendar: cal)
        XCTAssertTrue(cal.isDate(sel.day, inSameDayAs: at(21, 7)))
        XCTAssertEqual(sel.logTime(now: at(21, 7, 15), calendar: cal), at(21, 7, 15))
    }

    func test_day_selection_keeps_a_picked_day_and_logs_at_noon() {
        var sel = DaySelection(now: at(21, 9), calendar: cal)
        sel.shift(by: -1, now: at(21, 9), calendar: cal)
        sel.refresh(now: at(21, 10), calendar: cal)
        XCTAssertTrue(cal.isDate(sel.day, inSameDayAs: at(20, 12)))
        XCTAssertEqual(sel.logTime(now: at(21, 10), calendar: cal), at(20, 12))
        sel.shift(by: 1, now: at(21, 10), calendar: cal)
        XCTAssertTrue(sel.followsToday)
        sel.refresh(now: at(22, 8), calendar: cal)
        XCTAssertTrue(cal.isDate(sel.day, inSameDayAs: at(22, 8)))
    }

    func test_day_selection_never_goes_past_today() {
        var sel = DaySelection(now: at(21, 9), calendar: cal)
        sel.shift(by: 1, now: at(21, 9), calendar: cal)
        XCTAssertTrue(cal.isDate(sel.day, inSameDayAs: at(21, 9)))
    }

    // I4: items need stable identity for editing lists (and old JSON without ids still decodes)
    func test_entry_item_ids_are_stable_and_old_json_decodes() throws {
        let a = EntryItem(name: "Rice", grams: 200, nutrients: Nutrients(kcal: 260))
        let b = EntryItem(name: "Rice", grams: 200, nutrients: Nutrients(kcal: 260))
        XCTAssertNotEqual(a.id, b.id)
        let round = try JSONDecoder().decode(EntryItem.self, from: JSONEncoder().encode(a))
        XCTAssertEqual(round.id, a.id)
        let old = try JSONDecoder().decode(EntryItem.self, from: Data(#"{"name":"Old","grams":10,"nutrients":{"kcal":5}}"#.utf8))
        XCTAssertFalse(old.id.isEmpty)
        XCTAssertEqual(old.nutrients.kcal, 5)
    }
}

final class SyncReviewFixTests: XCTestCase {
    var clock = Date(timeIntervalSince1970: 1_795_000_000)
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

    func engine() -> SyncEngine {
        SyncEngine(store: store, api: SyncAPI(config: SyncConfig(baseURL: URL(string: "https://h.example/api/v1")!, token: "tok"),
                                              transport: server.transport),
                   reader: noop, photos: photos, now: { [unowned self] in self.clock })
    }

    func daily(_ n: Int) -> [SyncRecord] {
        (0..<n).map { SyncRecord(id: "d|\($0)", updatedAt: clock, deleted: false, data: ["day": .string("2026-11-\(10 + $0 % 10)")]) }
    }

    func tombstones(_ kind: String) -> [[String: Any]] {
        (server.ingested[kind] ?? []).filter { $0["deleted"] as? Bool == true }
    }

    // I2: a source that can't be read (NOOP's DB missing / moved) must not delete everything on the server
    func test_unavailable_source_sends_no_tombstones() async throws {
        noop.byKind[.daily_metrics] = daily(5)
        _ = await engine().syncAll(force: true)
        noop.unavailable = [.daily_metrics]
        let r = await engine().syncAll(force: true)
        XCTAssertNil(r.error)
        XCTAssertTrue(tombstones("daily_metrics").isEmpty)
        noop.unavailable = []
        _ = await engine().syncAll(force: true)
        XCTAssertEqual(server.ingested["daily_metrics"]?.count, 5)
    }

    // I2: NOOP keeps only 48 h of caffeine intakes; ageing out is not a deletion
    func test_caffeine_rows_never_tombstoned() async throws {
        noop.byKind[.noop_intake] = [
            SyncRecord(id: "caffeine|A", updatedAt: clock, deleted: false, data: ["at": .string("2026-11-17T08:00:00Z")]),
            SyncRecord(id: "hydration|h|2026-11-17|hydration", updatedAt: clock, deleted: false, data: ["at": .string("2026-11-17T11:00:00Z")]),
        ]
        _ = await engine().syncAll(force: true)
        noop.byKind[.noop_intake] = []
        _ = await engine().syncAll(force: true)
        XCTAssertEqual(tombstones("noop_intake").map { $0["id"] as? String }, ["hydration|h|2026-11-17|hydration"])
    }

    // I2: a sudden mass disappearance is suspicious (NOOP rewrote its tables); don't tombstone it
    func test_mass_removal_is_not_tombstoned() async throws {
        noop.byKind[.daily_metrics] = daily(100)
        _ = await engine().syncAll(force: true)
        noop.byKind[.daily_metrics] = Array(daily(100).prefix(10))
        let r = await engine().syncAll(force: true)
        XCTAssertNil(r.error)
        XCTAssertTrue(tombstones("daily_metrics").isEmpty)
        // a few real removals still go through
        noop.byKind[.daily_metrics] = Array(daily(100).prefix(98))
        _ = await engine().syncAll(force: true)
        XCTAssertEqual(tombstones("daily_metrics").count, 2)
    }

    // I5: when the server rejects everything, stop: quarantining every record would drop them for good
    func test_systematic_422_aborts_without_marking() async throws {
        for i in 0..<100 {
            try store.save(FoodEntry.new(id: "e\(i)", at: clock, meal: .lunch, method: .quick_add,
                                         items: [EntryItem(name: "x", grams: nil, nutrients: Nutrients(kcal: 1))]))
        }
        server.badIds = Set((0..<100).map { "e\($0)" })
        let r = await engine().syncAll(force: true)
        guard case .rejected? = r.error else { return XCTFail("expected rejected, got \(String(describing: r.error))") }
        XCTAssertEqual(try store.dirty(kind: .food_entries).count, 100)
        XCTAssertLessThan(server.transport.requests.count, 80)
        server.badIds = []
        _ = await engine().syncAll(force: true)
        XCTAssertEqual(server.ingested["food_entries"]?.count, 100)
    }

    // I5: rejected records can be sent again after the server is fixed
    func test_requeue_quarantined_resends() async throws {
        try store.save(FoodEntry.new(id: "bad-entry", at: clock, meal: .lunch, method: .quick_add,
                                     items: [EntryItem(name: "x", grams: nil, nutrients: Nutrients(kcal: 1))]))
        noop.byKind[.daily_metrics] = daily(3)
        server.badIds = ["bad-entry", "d|1"]
        _ = await engine().syncAll(force: true)
        XCTAssertEqual(try store.quarantined().count, 2)
        server.badIds = []
        try store.requeueQuarantined()
        XCTAssertTrue(try store.quarantined().isEmpty)
        _ = await engine().syncAll(force: true)
        XCTAssertTrue(server.ingested["food_entries"]!.contains { $0["id"] as? String == "bad-entry" })
        XCTAssertTrue(server.ingested["daily_metrics"]!.contains { $0["id"] as? String == "d|1" })
    }
}

final class QueueReviewFixTests: XCTestCase {
    var store: ExtrasStore!
    var photos: PhotoStore!
    var tmp: URL!
    let est = FoodEstimate(items: [.init(name: "Pasta", grams: 300, kcal: 520)], confidence: .medium, note: "")

    override func setUpWithError() throws {
        store = try ExtrasStore(db: ExtrasDatabase.inMemory())
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        photos = try PhotoStore(directory: tmp, store: store)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: tmp) }

    @discardableResult
    func pending() throws -> FoodEntry {
        var e = FoodEntry.new(at: Date(), meal: .dinner, method: .photo_ai, status: .pending)
        e.photoId = try photos.save(jpeg: sampleJPEG)
        try store.save(e)
        return e
    }

    // I3: opening the app without signal must not use up the retry budget
    func test_offline_and_timeout_do_not_use_attempts() async throws {
        let e = try pending()
        for err in [ProviderError.offline, .timeout, .offline, .timeout, .offline, .offline, .offline, .offline, .offline, .offline] {
            await EstimationQueue(store: store, photos: photos, provider: { StubProvider([.failure(err)]) }).runPending()
        }
        let after = try XCTUnwrap(store.entry(id: e.id))
        XCTAssertEqual(after.attempts, 0)
        XCTAssertEqual(after.status, .pending)
        let ran = await EstimationQueue(store: store, photos: photos, provider: { StubProvider([.success(self.est)]) }).runPending()
        XCTAssertEqual(ran, 1)
    }

    // I6: a new photo is estimated straight away, even while a backlog pass holds the queue
    func test_estimate_one_entry_directly() async throws {
        try pending()                      // backlog
        let fresh = try pending()
        let q = EstimationQueue(store: store, photos: photos, provider: { StubProvider([.success(self.est)]) })
        let ok = await q.estimate(entryId: fresh.id)
        XCTAssertTrue(ok)
        XCTAssertEqual(try store.entry(id: fresh.id)?.status, .logged)
        XCTAssertEqual(try store.pendingEntries().count, 1)
    }

    // I6: entries added while a pass runs are picked up by that pass
    func test_entries_added_during_a_run_are_picked_up() async throws {
        try pending()
        let p = StubProvider([.success(est), .success(est)])
        p.onCall = { [unowned self] n in if n == 1 { _ = try? self.pending() } }
        let ran = await EstimationQueue(store: store, photos: photos, provider: { p }).runPending()
        XCTAssertEqual(ran, 2)
        XCTAssertTrue(try store.pendingEntries().isEmpty)
    }
}
