import XCTest
@testable import NOOPExtras

final class LookupTests: XCTestCase {
    var store: ExtrasStore!
    var clock = Date(timeIntervalSince1970: 1_795_000_000)

    override func setUpWithError() throws {
        store = try ExtrasStore(db: ExtrasDatabase.inMemory(), now: { [unowned self] in self.clock })
    }

    func off(_ t: FakeTransport) -> OpenFoodFacts { OpenFoodFacts(transport: t, store: store, now: { [unowned self] in self.clock }) }

    func test_off_maps_product_units() async throws {
        let t = FakeTransport([.http(200, fixture("off_product.json"))])
        let food = try await XCTUnwrapAsync(await off(t).product(barcode: "5741000123456"))
        XCTAssertEqual(food.name, "Energidrik Original")
        XCTAssertEqual(food.brand, "Cult")
        XCTAssertEqual(food.barcode, "5741000123456")
        XCTAssertEqual(food.source, .off)
        XCTAssertEqual(food.per100.kcal, 46)
        XCTAssertEqual(food.per100.caffeineMg, 32, accuracy: 0.0001)
        XCTAssertEqual(food.per100.saltG, 0.2)
        XCTAssertEqual(food.servingG, 250)
        let r = t.requests[0]
        XCTAssertTrue(r.url!.absoluteString.hasPrefix("https://world.openfoodfacts.org/api/v2/product/5741000123456.json?fields="))
        XCTAssertEqual(r.value(forHTTPHeaderField: "User-Agent"), "NOOPExtras/1.0 (personal fork of NOOP)")
    }

    func test_off_alcohol_percent_and_kj_fallback() async throws {
        let t = FakeTransport([.http(200, fixture("off_beer.json"))])
        let food = try await XCTUnwrapAsync(await off(t).product(barcode: "5740700000000"))
        XCTAssertEqual(food.per100.alcoholG, 4.6 * 0.789, accuracy: 0.0001)
        XCTAssertEqual(food.per100.kcal, 172 / 4.184, accuracy: 0.01)
    }

    func test_off_not_found_is_nil() async throws {
        let t = FakeTransport([.http(200, fixture("off_notfound.json"))])
        let food = try await off(t).product(barcode: "0000000000000")
        XCTAssertNil(food)
    }

    func test_off_uses_cache() async throws {
        let t = FakeTransport([.http(200, fixture("off_product.json"))])
        _ = try await off(t).product(barcode: "5741000123456")
        let again = try await off(t).product(barcode: "5741000123456")
        XCTAssertEqual(again?.name, "Energidrik Original")
        XCTAssertEqual(t.requests.count, 1)
        clock += 31 * 86400
        t.replies = [.http(200, fixture("off_product.json"))]
        _ = try await off(t).product(barcode: "5741000123456")
        XCTAssertEqual(t.requests.count, 2)
    }

    func test_off_rejects_non_digit_barcode() async throws {
        let t = FakeTransport()
        let food = try await off(t).product(barcode: "../../etc")
        XCTAssertNil(food)
        XCTAssertEqual(t.requests.count, 0)
    }

    func test_off_search_skips_nameless() async throws {
        let t = FakeTransport([.http(200, fixture("off_search.json"))])
        let foods = try await off(t).search("skyr")
        XCTAssertEqual(foods.map(\.name), ["Skyr naturel", "Skyr vanilje"])
        XCTAssertTrue(t.requests[0].url!.absoluteString.contains("search_terms=skyr"))
    }

    func test_generic_search_finds_oats_and_chicken_breast() {
        let oats = GenericFoods.shared.search("oats")
        XCTAssertFalse(oats.isEmpty)
        XCTAssertTrue(oats.prefix(10).contains { $0.name.lowercased().contains("oats") })
        let chicken = GenericFoods.shared.search("chicken breast roasted")
        let first = chicken.first { $0.name.hasPrefix("Chicken, broilers or fryers, breast, meat only, cooked, roasted") }
        XCTAssertEqual(first?.per100.kcal, 165)
        XCTAssertEqual(first?.source, .generic)
        XCTAssertGreaterThan(GenericFoods.shared.count, 5000)
        XCTAssertTrue(GenericFoods.shared.search("").isEmpty)
    }

    func test_generic_ids_are_stable() {
        let a = GenericFoods.shared.search("oats").first?.id
        let b = GenericFoods.shared.search("oats").first?.id
        XCTAssertNotNil(a)
        XCTAssertEqual(a, b)
    }

    func test_drink_preset_to_entry() {
        let beer = Drinks.defaults.first { $0.name == "Beer" }!
        XCTAssertEqual(beer.alcoholG, 12, accuracy: 0.5)
        let e = beer.entry(at: clock, meal: .dinner)
        XCTAssertEqual(e.method, .quick_add)
        XCTAssertEqual(e.totals.kcal, beer.kcal)
        XCTAssertEqual(e.totals.alcoholG, beer.alcoholG)
        XCTAssertEqual(e.items.first?.grams, beer.ml)
        let coffee = Drinks.defaults.first { $0.name == "Coffee" }!
        XCTAssertEqual(coffee.entry(at: clock, meal: .breakfast).totals.caffeineMg, 95)
    }

    func test_drink_presets_editable_round_trip() throws {
        var presets = Drinks.load(store: store)
        XCTAssertEqual(presets, Drinks.defaults)
        presets[0].caffeineMg = 120
        try Drinks.save(presets, store: store)
        XCTAssertEqual(Drinks.load(store: store)[0].caffeineMg, 120)
    }
}

func XCTUnwrapAsync<T>(_ v: T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    try XCTUnwrap(v, file: file, line: line)
}
