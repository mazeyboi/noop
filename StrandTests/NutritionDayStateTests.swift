import XCTest
@testable import Strand

final class NutritionDayStateTests: XCTestCase {
    func testFreshDayStartsAtZero() {
        let state = NutritionDayState()

        XCTAssertEqual(state.totalCalories, 0)
        for meal in NutritionMeal.allCases {
            XCTAssertEqual(state.calories(for: meal), 0)
        }
    }

    func testAddingCaloriesUpdatesDayAndSelectedMeal() {
        var state = NutritionDayState()

        state.addCalories(420, to: .lunch)

        XCTAssertEqual(state.totalCalories, 420)
        XCTAssertEqual(state.calories(for: .lunch), 420)
        XCTAssertEqual(state.calories(for: .breakfast), 0)
    }

    func testCaloriesAccumulateWithinMeal() {
        var state = NutritionDayState()

        state.addCalories(200, to: .snacks)
        state.addCalories(150, to: .snacks)

        XCTAssertEqual(state.totalCalories, 350)
        XCTAssertEqual(state.calories(for: .snacks), 350)
    }

    func testNonPositiveCaloriesAreIgnored() {
        var state = NutritionDayState()

        state.addCalories(0, to: .dinner)
        state.addCalories(-100, to: .dinner)

        XCTAssertEqual(state.totalCalories, 0)
        XCTAssertEqual(state.calories(for: .dinner), 0)
    }
}
