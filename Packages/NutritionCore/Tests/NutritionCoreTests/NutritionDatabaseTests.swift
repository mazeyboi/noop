import XCTest
@testable import NutritionCore

final class NutritionDatabaseTests: XCTestCase {
    func testMigrationCreatesFoodAndEntrySchemas() async throws {
        let database = try NutritionDatabase.inMemory()

        let tables = try await database.tableNamesForTesting()
        let foodColumns = try await database.columnNamesForTesting(table: "nutritionFood")

        XCTAssertTrue(tables.isSuperset(of: ["nutritionFood", "nutritionLogEntry", "grdb_migrations"]))
        XCTAssertEqual(
            foodColumns,
            [
                "id", "name", "brand", "caloriesPer100g", "proteinPer100g", "carbohydratesPer100g",
                "fatPer100g", "servingAmount", "servingUnitSingular", "servingUnitPlural", "servingGrams",
                "source", "barcode", "isFavourite", "createdAt", "updatedAt",
            ]
        )
    }

    func testFoodCRUDSearchAndFavourites() async throws {
        let database = try NutritionDatabase.inMemory()
        var oats = NutritionFood(
            name: "Rolled oats",
            brand: "Mill",
            nutrientsPer100Grams: NutritionMacros(calories: 380, protein: 13, carbohydrates: 67, fat: 7),
            serving: NutritionServing(amount: 1, unitSingular: "bowl", unitPlural: "bowls", grams: 80),
            source: .custom
        )
        try await database.saveFood(oats)

        let searchMatches = try await database.searchFoods("oat")
        XCTAssertEqual(searchMatches.map(\.id), [oats.id])

        oats.isFavourite = true
        oats.name = "Breakfast oats"
        try await database.saveFood(oats)
        let favourites = try await database.favouriteFoods()
        XCTAssertEqual(favourites.map(\.name), ["Breakfast oats"])

        try await database.deleteFood(id: oats.id)
        let afterDelete = try await database.searchFoods("")
        XCTAssertTrue(afterDelete.isEmpty)
    }

    func testLoggingPlatePersistsEntriesAndMealDayTotals() async throws {
        let database = try NutritionDatabase.inMemory()
        let food = NutritionFood(
            name: "Rice",
            nutrientsPer100Grams: NutritionMacros(calories: 130, protein: 2.7, carbohydrates: 28, fat: 0.3),
            source: .custom
        )
        try await database.saveFood(food)
        let quick = NutritionPlateItem.quickAdd(
            name: nil,
            macros: NutritionMacros(calories: 100, protein: 10, carbohydrates: 5, fat: 4)
        )
        let plate = NutritionPlate(
            items: [NutritionPlateItem(food: food, quantityGrams: 200), quick],
            meal: .dinner
        )

        let logged = try await database.log(plate: plate, localDate: "2026-09-10")
        let summary = try await database.daySummary(localDate: "2026-09-10")

        XCTAssertEqual(logged.count, 2)
        XCTAssertEqual(summary.entries.count, 2)
        XCTAssertEqual(summary.macros.calories, 360, accuracy: 0.001)
        XCTAssertEqual(summary.macros(for: .dinner).calories, 360, accuracy: 0.001)
        XCTAssertEqual(summary.macros(for: .breakfast), .zero)
    }

    func testQuickAddDoesNotCreateSearchableLibraryFood() async throws {
        let database = try NutritionDatabase.inMemory()
        let plate = NutritionPlate(
            items: [.quickAdd(name: "Restaurant meal", macros: NutritionMacros(calories: 650))],
            meal: .dinner
        )

        _ = try await database.log(plate: plate, localDate: "2026-09-10")
        let library = try await database.searchFoods("")
        let summary = try await database.daySummary(localDate: "2026-09-10")

        XCTAssertTrue(library.isEmpty)
        XCTAssertEqual(summary.entries.map(\.name), ["Restaurant meal"])
    }

    func testDaysAreIsolatedAndDatabaseSurvivesReopen() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("nutrition.sqlite").path
        let first = try NutritionDatabase(path: path)
        let plate = NutritionPlate(
            items: [.quickAdd(name: "Coffee", macros: NutritionMacros(calories: 40))],
            meal: .breakfast
        )
        _ = try await first.log(plate: plate, localDate: "2026-09-10")

        let reopened = try NutritionDatabase(path: path)
        let savedDay = try await reopened.daySummary(localDate: "2026-09-10")
        let emptyDay = try await reopened.daySummary(localDate: "2026-09-11")

        XCTAssertEqual(savedDay.macros.calories, 40)
        XCTAssertTrue(emptyDay.entries.isEmpty)
    }

    func testEditDuplicateDeleteAndRestoreLoggedEntry() async throws {
        let database = try NutritionDatabase.inMemory()
        let food = NutritionFood(
            name: "Pasta",
            nutrientsPer100Grams: NutritionMacros(calories: 150, protein: 5, carbohydrates: 30, fat: 1),
            source: .custom
        )
        try await database.saveFood(food)
        let plate = NutritionPlate(items: [NutritionPlateItem(food: food, quantityGrams: 100)], meal: .lunch)
        let logged = try await database.log(plate: plate, localDate: "2026-09-10")
        let original = try XCTUnwrap(logged.first)

        let edited = original.scaled(toGrams: 200)
        try await database.updateEntry(edited)
        let duplicate = try await database.duplicateEntry(id: original.id, loggedAt: Date(timeIntervalSince1970: 10))
        let deleted = try await database.deleteEntry(id: original.id)

        XCTAssertEqual(edited.macros.calories, 300)
        XCTAssertNotEqual(duplicate.id, original.id)
        XCTAssertEqual(deleted?.id, original.id)
        let afterDelete = try await database.daySummary(localDate: "2026-09-10")
        XCTAssertEqual(afterDelete.entries.count, 1)

        let deletedEntry = try XCTUnwrap(deleted)
        try await database.restoreEntry(deletedEntry)
        let afterRestore = try await database.daySummary(localDate: "2026-09-10")
        XCTAssertEqual(afterRestore.entries.count, 2)
    }

    func testRecentsFrequencyAndRememberedQuantity() async throws {
        let database = try NutritionDatabase.inMemory()
        let banana = NutritionFood(
            name: "Banana",
            nutrientsPer100Grams: NutritionMacros(calories: 89, protein: 1.1, carbohydrates: 23, fat: 0.3),
            source: .custom
        )
        let yogurt = NutritionFood(
            name: "Yogurt",
            nutrientsPer100Grams: NutritionMacros(calories: 80, protein: 8, carbohydrates: 6, fat: 2),
            source: .custom
        )
        try await database.saveFood(banana)
        try await database.saveFood(yogurt)
        _ = try await database.log(
            plate: NutritionPlate(items: [NutritionPlateItem(food: banana, quantityGrams: 118)], meal: .breakfast),
            localDate: "2026-09-08",
            loggedAt: Date(timeIntervalSince1970: 1)
        )
        _ = try await database.log(
            plate: NutritionPlate(items: [NutritionPlateItem(food: yogurt, quantityGrams: 200)], meal: .snacks),
            localDate: "2026-09-09",
            loggedAt: Date(timeIntervalSince1970: 2)
        )
        _ = try await database.log(
            plate: NutritionPlate(items: [NutritionPlateItem(food: banana, quantityGrams: 150)], meal: .breakfast),
            localDate: "2026-09-10",
            loggedAt: Date(timeIntervalSince1970: 3)
        )

        let recents = try await database.recentFoods(limit: 2)
        let frequent = try await database.frequentFoods(limit: 2)
        let lastQuantity = try await database.lastQuantityGrams(foodID: banana.id)
        XCTAssertEqual(recents.map(\.id), [banana.id, yogurt.id])
        XCTAssertEqual(frequent.map(\.id).first, banana.id)
        XCTAssertEqual(lastQuantity, 150)
    }

    func testDeletingCustomFoodPreservesLoggedSnapshot() async throws {
        let database = try NutritionDatabase.inMemory()
        let food = NutritionFood(
            name: "Family recipe",
            nutrientsPer100Grams: NutritionMacros(calories: 210, protein: 12, carbohydrates: 18, fat: 10),
            source: .custom
        )
        try await database.saveFood(food)
        _ = try await database.log(
            plate: NutritionPlate(items: [NutritionPlateItem(food: food, quantityGrams: 100)], meal: .dinner),
            localDate: "2026-09-10"
        )

        try await database.deleteFood(id: food.id)
        let summary = try await database.daySummary(localDate: "2026-09-10")
        let entry = try XCTUnwrap(summary.entries.first)

        XCTAssertNil(entry.foodID)
        XCTAssertEqual(entry.name, "Family recipe")
        XCTAssertEqual(entry.macros.calories, 210)
    }
}
