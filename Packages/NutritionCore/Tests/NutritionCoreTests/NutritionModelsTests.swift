import XCTest
@testable import NutritionCore

final class NutritionModelsTests: XCTestCase {
    func testMacroArithmeticAndApproximateContribution() {
        let macros = NutritionMacros(calories: 500, protein: 30, carbohydrates: 50, fat: 20)

        XCTAssertEqual(macros.approximateMacroCalories, 500, accuracy: 0.001)
        XCTAssertEqual(macros.scaled(by: 0.5), NutritionMacros(calories: 250, protein: 15, carbohydrates: 25, fat: 10))
    }

    func testFoodScalesFromCanonicalHundredGramProfile() {
        let food = NutritionFood(
            name: "Greek yogurt",
            nutrientsPer100Grams: NutritionMacros(calories: 120, protein: 10, carbohydrates: 8, fat: 4),
            source: .custom
        )

        let item = NutritionPlateItem(food: food, quantityGrams: 250)

        XCTAssertEqual(item.macros.calories, 300, accuracy: 0.001)
        XCTAssertEqual(item.macros.protein, 25, accuracy: 0.001)
    }

    func testServingMetadataConvertsCountsToGrams() throws {
        let serving = NutritionServing(
            amount: 1,
            unitSingular: "egg",
            unitPlural: "eggs",
            grams: 50
        )
        let food = NutritionFood(
            name: "Egg",
            nutrientsPer100Grams: NutritionMacros(calories: 140, protein: 12, carbohydrates: 1, fat: 10),
            serving: serving,
            source: .custom
        )

        let item = NutritionPlateItem(food: food, servingCount: 3)

        XCTAssertEqual(try XCTUnwrap(item.quantityGrams), 150, accuracy: 0.001)
        XCTAssertEqual(item.macros.calories, 210, accuracy: 0.001)
        XCTAssertEqual(item.quantityDescription, "3 eggs")
    }

    func testQuickAddUsesDirectTotalsWithoutInventingGrams() {
        let item = NutritionPlateItem.quickAdd(
            name: nil,
            macros: NutritionMacros(calories: 275, protein: 12, carbohydrates: 30, fat: 9)
        )

        XCTAssertNil(item.quantityGrams)
        XCTAssertEqual(item.name, "Quick Add")
        XCTAssertEqual(item.macros.calories, 275)
        XCTAssertEqual(item.source, .quickAdd)
    }

    func testLocalDateUsesRequestedCalendarTimeZone() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        var losAngeles = Calendar(identifier: .gregorian)
        losAngeles.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let date = Date(timeIntervalSince1970: 1_767_225_600) // 2026-01-01 00:00 UTC

        XCTAssertEqual(NutritionLocalDate.key(for: date, calendar: utc), "2026-01-01")
        XCTAssertEqual(NutritionLocalDate.key(for: date, calendar: losAngeles), "2025-12-31")
        XCTAssertTrue(NutritionLocalDate.isValid("2026-02-28"))
        XCTAssertFalse(NutritionLocalDate.isValid("2026-02-30"))
    }
}
