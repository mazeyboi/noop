import XCTest
@testable import NutritionCore

final class NutritionParsingTests: XCTestCase {
    func testGeminiResponseNormalizesDetectedFoodsIntoEditablePlateItems() throws {
        let data = Data(#"{"candidates":[{"content":{"parts":[{"text":"{\"foods\":[{\"name\":\"Salmon\",\"grams\":140,\"calories\":290,\"protein\":31,\"carbohydrates\":0,\"fat\":18}]}"}]}}]}"#.utf8)

        let items = try GeminiNutritionParser.parseResponse(data)

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].name, "Salmon")
        XCTAssertEqual(items[0].quantityGrams, 140)
        XCTAssertEqual(items[0].macros.protein, 31)
        XCTAssertEqual(items[0].source, .geminiEstimate)
    }

    func testGeminiParserSkipsIncompleteRowsButKeepsValidRows() throws {
        let data = Data(#"{"candidates":[{"content":{"parts":[{"text":"{\"foods\":[{\"name\":\"\",\"grams\":50,\"calories\":20},{\"name\":\"Rice\",\"grams\":180,\"calories\":234,\"protein\":4.3,\"carbohydrates\":51,\"fat\":0.5}]}"}]}}]}"#.utf8)

        let items = try GeminiNutritionParser.parseResponse(data)

        XCTAssertEqual(items.map(\.name), ["Rice"])
    }

    func testGeminiParserRejectsMalformedOrUnsafeOutput() {
        let malformed = Data(#"{"candidates":[{"content":{"parts":[{"text":"not json"}]}}]}"#.utf8)
        let negative = Data(#"{"candidates":[{"content":{"parts":[{"text":"{\"foods\":[{\"name\":\"Rice\",\"grams\":-2,\"calories\":20}]}"}]}}]}"#.utf8)

        XCTAssertThrowsError(try GeminiNutritionParser.parseResponse(malformed))
        XCTAssertThrowsError(try GeminiNutritionParser.parseResponse(negative))
    }

    func testOpenFoodFactsNormalizesPerHundredGramNutritionAndServing() throws {
        let data = Data(#"{"status":1,"product":{"product_name":"Skyr","brands":"Example Dairy","serving_size":"150 g","serving_quantity":150,"nutriments":{"energy-kcal_100g":64,"proteins_100g":11.0,"carbohydrates_100g":3.8,"fat_100g":0.2}}}"#.utf8)

        let food = try OpenFoodFactsNormalizer.food(from: data, barcode: "12345678")

        XCTAssertEqual(food.name, "Skyr")
        XCTAssertEqual(food.brand, "Example Dairy")
        XCTAssertEqual(food.barcode, "12345678")
        XCTAssertEqual(food.nutrientsPer100Grams.calories, 64)
        XCTAssertEqual(food.serving?.grams, 150)
        XCTAssertEqual(food.source, .openFoodFacts)
    }

    func testOpenFoodFactsHandlesNotFoundAndMalformedNutrition() {
        let notFound = Data(#"{"status":0,"status_verbose":"product not found"}"#.utf8)
        let malformed = Data(#"{"status":1,"product":{"product_name":"Mystery","nutriments":{"proteins_100g":"nope"}}}"#.utf8)

        XCTAssertThrowsError(try OpenFoodFactsNormalizer.food(from: notFound, barcode: "0")) { error in
            XCTAssertEqual(error as? OpenFoodFactsError, .productNotFound)
        }
        XCTAssertThrowsError(try OpenFoodFactsNormalizer.food(from: malformed, barcode: "1")) { error in
            XCTAssertEqual(error as? OpenFoodFactsError, .malformedNutrition)
        }
    }

    func testServingParserUsesMetadataRatherThanFoodName() {
        XCTAssertEqual(
            NutritionServingParser.parse("2 slices (56 g)"),
            NutritionServing(amount: 2, unitSingular: "slice", unitPlural: "slices", grams: 56)
        )
        XCTAssertEqual(
            NutritionServingParser.parse("1 banana (118 g)"),
            NutritionServing(amount: 1, unitSingular: "banana", unitPlural: "bananas", grams: 118)
        )
    }
}
