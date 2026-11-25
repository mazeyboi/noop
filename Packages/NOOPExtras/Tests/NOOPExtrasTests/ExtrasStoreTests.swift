import XCTest
@testable import NOOPExtras

final class ExtrasStoreTests: XCTestCase {
    var clock = Date(timeIntervalSince1970: 1_795_000_000) // 2026-11-17
    var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Copenhagen")!
        return c
    }()
    var store: ExtrasStore!

    override func setUpWithError() throws {
        store = try ExtrasStore(db: ExtrasDatabase.inMemory(), now: { [unowned self] in self.clock })
    }

    func day(_ d: Int, _ h: Int = 12) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 11, day: d, hour: h))!
    }

    func logged(_ kcal: Double, at: Date, meal: MealType = .lunch) -> FoodEntry {
        FoodEntry.new(at: at, meal: meal, method: .quick_add,
                      items: [EntryItem(name: "x", grams: nil, nutrients: Nutrients(kcal: kcal))])
    }

    func test_save_and_read_day_entries() throws {
        try store.save(logged(300, at: day(20, 8), meal: .breakfast))
        try store.save(logged(500, at: day(20, 19), meal: .dinner))
        try store.save(logged(999, at: day(21, 1)))
        let entries = try store.entries(on: day(20), calendar: cal)
        XCTAssertEqual(entries.map(\.totals.kcal), [300, 500])
        XCTAssertEqual(entries.first?.meal, .breakfast)
    }

    func test_day_totals_excludes_pending_and_counts_it() throws {
        try store.save(logged(300, at: day(20, 8)))
        var pending = FoodEntry.new(at: day(20, 13), meal: .lunch, method: .photo_ai, status: .pending)
        pending.photoId = "p1"
        try store.save(pending)
        let t = try store.dayTotals(on: day(20), calendar: cal)
        XCTAssertEqual(t.logged.kcal, 300)
        XCTAssertEqual(t.pendingCount, 1)
    }

    func test_delete_is_tombstone_and_dirty() throws {
        let e = logged(300, at: day(20))
        try store.save(e)
        try store.markSynced(kind: .food_entries, records: store.dirty(kind: .food_entries))
        XCTAssertTrue(try store.dirty(kind: .food_entries).isEmpty)
        clock += 60
        try store.deleteEntry(id: e.id)
        XCTAssertTrue(try store.entries(on: day(20), calendar: cal).isEmpty)
        let dirty = try store.dirty(kind: .food_entries)
        XCTAssertEqual(dirty.map(\.id), [e.id])
        XCTAssertEqual(dirty.first?.deleted, true)
    }

    func test_undelete_restores_entry_and_marks_dirty() throws {
        let e = logged(300, at: day(20))
        try store.save(e)
        try store.deleteEntry(id: e.id)
        try store.markSynced(kind: .food_entries, records: store.dirty(kind: .food_entries))
        clock += 60
        try store.undeleteEntry(id: e.id)
        XCTAssertEqual(try store.entries(on: day(20), calendar: cal).map(\.id), [e.id])
        XCTAssertEqual(try store.dirty(kind: .food_entries).first?.deleted, false)
    }

    func test_mark_synced_keeps_dirty_if_edited_after_send() throws {
        var e = logged(300, at: day(20))
        try store.save(e)
        let sent = try store.dirty(kind: .food_entries)
        clock += 5
        e.items[0].nutrients.kcal = 350
        e.edited = true
        try store.save(e)
        try store.markSynced(kind: .food_entries, records: sent)
        XCTAssertEqual(try store.dirty(kind: .food_entries).count, 1)
    }

    func test_record_data_shape_for_server() throws {
        var e = FoodEntry.new(at: day(20, 13), meal: .lunch, method: .photo_ai, status: .pending)
        e.photoId = "p1"
        try store.save(e)
        let r = try XCTUnwrap(store.dirty(kind: .food_entries).first)
        XCTAssertEqual(r.data["method"], .string("photo_ai"))
        XCTAssertEqual(r.data["photo_id"], .string("p1"))
        guard case .string(let at)? = r.data["at"] else { return XCTFail("at missing") }
        XCTAssertTrue(at.hasSuffix("Z"), at)
        XCTAssertNotNil(ISO8601DateFormatter.extras.date(from: at))
    }

    func test_recent_and_favourites() throws {
        let oats = Food(name: "Oats", source: .generic, per100: Nutrients(kcal: 379))
        let milk = Food(name: "Milk", source: .generic, per100: Nutrients(kcal: 64))
        try store.save(oats); try store.save(milk)
        var e = FoodEntry.new(at: day(20, 8), meal: .breakfast, method: .search, items: [oats.item(grams: 60)])
        try store.save(e)
        clock += 10
        e = FoodEntry.new(at: day(20, 9), meal: .breakfast, method: .search, items: [milk.item(grams: 200)])
        try store.save(e)
        XCTAssertEqual(try store.recentFoods(limit: 10).map(\.name), ["Milk", "Oats"])
        try store.setFavourite(foodId: oats.id, true)
        XCTAssertEqual(try store.favourites().map(\.name), ["Oats"])
    }

    func test_saved_meal_logs_entries() throws {
        let meal = SavedMeal(name: "Usual breakfast", items: [
            EntryItem(name: "Oats", grams: 60, nutrients: Nutrients(kcal: 227)),
            EntryItem(name: "Milk", grams: 200, nutrients: Nutrients(kcal: 128)),
        ])
        try store.save(meal)
        XCTAssertEqual(try store.savedMeals().map(\.name), ["Usual breakfast"])
        let entry = try store.logSavedMeal(meal, at: day(20, 8), meal: .breakfast)
        XCTAssertEqual(entry.totals.kcal, 355)
        XCTAssertEqual(entry.method, .search)
        XCTAssertEqual(try store.dayTotals(on: day(20), calendar: cal).logged.kcal, 355)
    }

    func test_copy_yesterdays_meal() throws {
        try store.save(logged(400, at: day(19, 8), meal: .breakfast))
        try store.save(logged(700, at: day(19, 19), meal: .dinner))
        let copied = try store.copyMeal(from: day(19), meal: .breakfast, to: day(20, 8), calendar: cal)
        XCTAssertEqual(copied.count, 1)
        XCTAssertEqual(try store.dayTotals(on: day(20), calendar: cal).logged.kcal, 400)
        XCTAssertNotEqual(copied.first?.id, try store.entries(on: day(19), calendar: cal).first?.id)
    }

    func test_reestimate_does_not_overwrite_edited_entry() throws {
        var e = FoodEntry.new(at: day(20, 13), meal: .lunch, method: .photo_ai, status: .logged,
                              items: [EntryItem(name: "my pasta", grams: 300, nutrients: Nutrients(kcal: 650))])
        e.edited = true
        try store.save(e)
        let est = FoodEstimate(items: [.init(name: "pasta", grams: 250, kcal: 400)], confidence: .medium, note: "")
        let after = try store.applyEstimate(est, to: e.id, provider: "anthropic", model: "m")
        XCTAssertEqual(after?.totals.kcal, 650)
        XCTAssertEqual(after?.aiOriginal, est)
        XCTAssertEqual(after?.status, .logged)
    }

    func test_apply_estimate_fills_unedited_entry() throws {
        var e = FoodEntry.new(at: day(20, 13), meal: .lunch, method: .photo_ai, status: .pending)
        e.error = "offline"
        try store.save(e)
        let est = FoodEstimate(items: [.init(name: "pasta", grams: 250, kcal: 400)], confidence: .low, note: "n")
        let after = try XCTUnwrap(store.applyEstimate(est, to: e.id, provider: "openai", model: "m"))
        XCTAssertEqual(after.totals.kcal, 400)
        XCTAssertEqual(after.status, .logged)
        XCTAssertEqual(after.confidence, .low)
        XCTAssertEqual(after.aiProvider, "openai")
        XCTAssertNil(after.error)
        XCTAssertFalse(after.edited)
    }

    func test_targets_round_trip() throws {
        XCTAssertNil(try store.targets())
        try store.save(Targets(kcal: 2200, proteinG: 150, carbsG: 220, fatG: 70))
        XCTAssertEqual(try store.targets()?.kcal, 2200)
        XCTAssertEqual(try store.dirty(kind: .targets).map(\.id), ["default"])
    }

    func test_quarantine_and_kv() throws {
        try store.quarantine(kind: .food_entries, id: "a", error: "bad", payload: "{}")
        XCTAssertEqual(try store.quarantined().map(\.id), ["a"])
        try store.setKV("k", "v")
        XCTAssertEqual(try store.kv("k"), "v")
        try store.setKV("k", nil)
        XCTAssertNil(try store.kv("k"))
    }

    func test_restore_replaces_everything() throws {
        try store.save(logged(1, at: day(20)))
        let snap = RestoreSnapshot(
            foods: [SyncRecord(id: "f1", updatedAt: day(18), deleted: false,
                               data: try ExtrasCodec.data(Food(id: "f1", name: "Rye bread", source: .custom,
                                                               per100: Nutrients(kcal: 220))))],
            meals: [], targets: [],
            entries: [SyncRecord(id: "e1", updatedAt: day(18), deleted: false,
                                 data: try ExtrasCodec.data(logged(222, at: day(18))))])
        try store.replaceAll(fromRestore: snap)
        XCTAssertEqual(try store.entries(on: day(20), calendar: cal).count, 0)
        XCTAssertEqual(try store.entries(on: day(18), calendar: cal).map(\.id), ["e1"])
        XCTAssertEqual(try store.dirty(kind: .food_entries).count, 0)
        XCTAssertEqual(try store.recentFoods(limit: 5).count + (try store.food(id: "f1") == nil ? 0 : 1), 1)
    }
}
