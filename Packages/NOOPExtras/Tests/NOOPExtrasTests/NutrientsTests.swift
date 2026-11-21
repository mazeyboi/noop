import XCTest
@testable import NOOPExtras

final class NutrientsTests: XCTestCase {
    func test_per100_scales_to_grams() {
        let chicken = Nutrients(kcal: 165, proteinG: 31, carbsG: 0, fatG: 3.6)
        let portion = chicken.per100(toGrams: 150)
        XCTAssertEqual(portion.kcal, 247.5, accuracy: 0.001)
        XCTAssertEqual(portion.proteinG, 46.5, accuracy: 0.001)
        XCTAssertEqual(portion.fatG, 5.4, accuracy: 0.001)
    }

    func test_sum_of_items() {
        let items = [
            EntryItem(name: "rice", grams: 200, nutrients: Nutrients(kcal: 260, carbsG: 56)),
            EntryItem(name: "beer", grams: 330, nutrients: Nutrients(kcal: 142, alcoholG: 12)),
        ]
        let total = EntryItem.total(items)
        XCTAssertEqual(total.kcal, 402, accuracy: 0.001)
        XCTAssertEqual(total.carbsG, 56, accuracy: 0.001)
        XCTAssertEqual(total.alcoholG, 12, accuracy: 0.001)
        XCTAssertEqual(EntryItem.total([]), .zero)
    }

    func test_meal_suggestion_boundaries() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Copenhagen")!
        func at(_ h: Int, _ m: Int) -> Date {
            cal.date(from: DateComponents(year: 2026, month: 11, day: 21, hour: h, minute: m))!
        }
        XCTAssertEqual(MealType.suggested(for: at(7, 0), calendar: cal), .breakfast)
        XCTAssertEqual(MealType.suggested(for: at(10, 29), calendar: cal), .breakfast)
        XCTAssertEqual(MealType.suggested(for: at(10, 30), calendar: cal), .lunch)
        XCTAssertEqual(MealType.suggested(for: at(14, 59), calendar: cal), .lunch)
        XCTAssertEqual(MealType.suggested(for: at(15, 0), calendar: cal), .snack)
        XCTAssertEqual(MealType.suggested(for: at(17, 30), calendar: cal), .dinner)
        XCTAssertEqual(MealType.suggested(for: at(21, 0), calendar: cal), .snack)
        XCTAssertEqual(MealType.suggested(for: at(2, 0), calendar: cal), .snack)
    }

    func test_entry_totals_follow_items() {
        var e = FoodEntry.new(at: Date(timeIntervalSince1970: 0), meal: .lunch, method: .quick_add)
        e.items = [EntryItem(name: "x", grams: nil, nutrients: Nutrients(kcal: 500))]
        XCTAssertEqual(e.totals.kcal, 500)
    }
}
