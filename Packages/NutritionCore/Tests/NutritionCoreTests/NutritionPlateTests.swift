import XCTest
@testable import NutritionCore

final class NutritionPlateTests: XCTestCase {
    private let apple = NutritionFood(
        name: "Apple",
        nutrientsPer100Grams: NutritionMacros(calories: 52, protein: 0.3, carbohydrates: 14, fat: 0.2),
        serving: NutritionServing(amount: 1, unitSingular: "apple", unitPlural: "apples", grams: 180),
        source: .custom
    )

    func testPlateAddsRemovesAndTotalsMultipleItems() {
        let appleItem = NutritionPlateItem(food: apple, quantityGrams: 180)
        let quickAdd = NutritionPlateItem.quickAdd(
            name: "Sauce",
            macros: NutritionMacros(calories: 40, protein: 0, carbohydrates: 8, fat: 1)
        )
        var plate = NutritionPlate(meal: .lunch)

        plate.add(appleItem)
        plate.add(quickAdd)
        XCTAssertEqual(plate.items.count, 2)
        XCTAssertEqual(plate.macros.calories, 133.6, accuracy: 0.001)

        plate.remove(id: quickAdd.id)
        XCTAssertEqual(plate.items, [appleItem])
    }

    func testPlateQuantityEditImmediatelyRecalculatesNutrition() {
        let item = NutritionPlateItem(food: apple, quantityGrams: 100)
        var plate = NutritionPlate(items: [item], meal: .snacks)

        plate.setGrams(250, for: item.id)

        XCTAssertEqual(plate.items[0].quantityGrams, 250)
        XCTAssertEqual(plate.macros.calories, 130, accuracy: 0.001)
    }

    func testPlateRejectsInvalidQuantitiesAndUnknownIDs() {
        let item = NutritionPlateItem(food: apple, quantityGrams: 100)
        var plate = NutritionPlate(items: [item], meal: .breakfast)

        plate.setGrams(-1, for: item.id)
        plate.setGrams(250, for: UUID())

        XCTAssertEqual(plate.items[0].quantityGrams, 100)
    }
}
