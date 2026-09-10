import Foundation

public enum NutritionLimits {
    public static let maximumGrams = 1_000_000.0
    public static let maximumNutrientValue = 1_000_000.0
    public static let maximumServingAmount = 100_000.0
}

public enum NutritionMeal: String, CaseIterable, Codable, Identifiable, Sendable {
    case breakfast
    case lunch
    case dinner
    case snacks

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .breakfast: return "Breakfast"
        case .lunch: return "Lunch"
        case .dinner: return "Dinner"
        case .snacks: return "Snacks"
        }
    }
}

public enum NutritionSource: String, Codable, Sendable {
    case custom
    case openFoodFacts = "open-food-facts"
    case geminiEstimate = "gemini-estimate"
    case quickAdd = "quick-add"
}

public struct NutritionMacros: Codable, Equatable, Sendable {
    public var calories: Double
    public var protein: Double
    public var carbohydrates: Double
    public var fat: Double

    public init(
        calories: Double = 0,
        protein: Double = 0,
        carbohydrates: Double = 0,
        fat: Double = 0
    ) {
        self.calories = calories
        self.protein = protein
        self.carbohydrates = carbohydrates
        self.fat = fat
    }

    public static let zero = NutritionMacros()

    public var approximateMacroCalories: Double {
        protein * 4 + carbohydrates * 4 + fat * 9
    }

    public var isValid: Bool {
        [calories, protein, carbohydrates, fat].allSatisfy {
            $0.isFinite && $0 >= 0 && $0 <= NutritionLimits.maximumNutrientValue
        }
    }

    public func scaled(by factor: Double) -> NutritionMacros {
        guard factor.isFinite, factor >= 0 else { return .zero }
        return NutritionMacros(
            calories: calories * factor,
            protein: protein * factor,
            carbohydrates: carbohydrates * factor,
            fat: fat * factor
        )
    }

    public static func + (lhs: NutritionMacros, rhs: NutritionMacros) -> NutritionMacros {
        NutritionMacros(
            calories: lhs.calories + rhs.calories,
            protein: lhs.protein + rhs.protein,
            carbohydrates: lhs.carbohydrates + rhs.carbohydrates,
            fat: lhs.fat + rhs.fat
        )
    }
}

public struct NutritionServing: Codable, Equatable, Sendable {
    public var amount: Double
    public var unitSingular: String
    public var unitPlural: String
    public var grams: Double

    public init(
        amount: Double,
        unitSingular: String,
        unitPlural: String,
        grams: Double
    ) {
        self.amount = amount
        self.unitSingular = unitSingular
        self.unitPlural = unitPlural
        self.grams = grams
    }

    public var isValid: Bool {
        amount.isFinite && amount > 0
            && amount <= NutritionLimits.maximumServingAmount
            && grams.isFinite && grams > 0 && grams <= NutritionLimits.maximumGrams
            && !unitSingular.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !unitPlural.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public func grams(forUnitCount count: Double) -> Double? {
        guard isValid, count.isFinite, count > 0 else { return nil }
        return grams * count / amount
    }

    public func unitCount(forGrams value: Double) -> Double? {
        guard isValid, value.isFinite, value > 0 else { return nil }
        return value * amount / grams
    }
}

public struct NutritionFood: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var brand: String?
    public var nutrientsPer100Grams: NutritionMacros
    public var serving: NutritionServing?
    public var source: NutritionSource
    public var barcode: String?
    public var isFavourite: Bool
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        brand: String? = nil,
        nutrientsPer100Grams: NutritionMacros,
        serving: NutritionServing? = nil,
        source: NutritionSource,
        barcode: String? = nil,
        isFavourite: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.brand = brand
        self.nutrientsPer100Grams = nutrientsPer100Grams
        self.serving = serving
        self.source = source
        self.barcode = barcode
        self.isFavourite = isFavourite
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && name.count <= 200
            && nutrientsPer100Grams.isValid
            && (serving == nil || serving?.isValid == true)
    }
}

public struct NutritionPlateItem: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var foodID: UUID?
    public var name: String
    public var brand: String?
    public var source: NutritionSource
    public var barcode: String?
    public var baseMacros: NutritionMacros
    public var baseQuantityGrams: Double?
    public var quantityGrams: Double?
    public var serving: NutritionServing?

    public init(
        id: UUID = UUID(),
        foodID: UUID? = nil,
        name: String,
        brand: String? = nil,
        source: NutritionSource,
        barcode: String? = nil,
        baseMacros: NutritionMacros,
        baseQuantityGrams: Double?,
        quantityGrams: Double?,
        serving: NutritionServing? = nil
    ) {
        self.id = id
        self.foodID = foodID
        self.name = name
        self.brand = brand
        self.source = source
        self.barcode = barcode
        self.baseMacros = baseMacros
        self.baseQuantityGrams = baseQuantityGrams
        self.quantityGrams = quantityGrams
        self.serving = serving
    }

    public init(food: NutritionFood, quantityGrams: Double? = nil) {
        let defaultGrams = quantityGrams ?? food.serving?.grams ?? 100
        self.init(
            foodID: food.id,
            name: food.name,
            brand: food.brand,
            source: food.source,
            barcode: food.barcode,
            baseMacros: food.nutrientsPer100Grams,
            baseQuantityGrams: 100,
            quantityGrams: defaultGrams,
            serving: food.serving
        )
    }

    public init(food: NutritionFood, servingCount: Double) {
        self.init(food: food, quantityGrams: food.serving?.grams(forUnitCount: servingCount))
    }

    public static func quickAdd(name: String?, macros: NutritionMacros) -> NutritionPlateItem {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        return NutritionPlateItem(
            name: trimmed.flatMap { $0.isEmpty ? nil : $0 } ?? "Quick Add",
            source: .quickAdd,
            baseMacros: macros,
            baseQuantityGrams: nil,
            quantityGrams: nil
        )
    }

    public static func estimate(name: String, grams: Double, macros: NutritionMacros) -> NutritionPlateItem {
        NutritionPlateItem(
            name: name,
            source: .geminiEstimate,
            baseMacros: macros,
            baseQuantityGrams: grams,
            quantityGrams: grams
        )
    }

    public var macros: NutritionMacros {
        guard let baseQuantityGrams,
              baseQuantityGrams.isFinite,
              baseQuantityGrams > 0,
              let quantityGrams,
              quantityGrams.isFinite,
              quantityGrams > 0 else {
            return baseMacros
        }
        return baseMacros.scaled(by: quantityGrams / baseQuantityGrams)
    }

    public var isValid: Bool {
        let baseQuantityIsValid = baseQuantityGrams.map {
            $0.isFinite && $0 > 0 && $0 <= NutritionLimits.maximumGrams
        } ?? true
        let quantityIsValid = quantityGrams.map {
            $0.isFinite && $0 > 0 && $0 <= NutritionLimits.maximumGrams
        } ?? true
        return !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && name.count <= 200
            && baseMacros.isValid
            && macros.isValid
            && baseQuantityIsValid
            && quantityIsValid
    }

    public var quantityDescription: String {
        if let quantityGrams,
           let serving,
           let units = serving.unitCount(forGrams: quantityGrams) {
            let unit = abs(units - 1) < 0.0001 ? serving.unitSingular : serving.unitPlural
            return "\(Self.formatted(units)) \(unit)"
        }
        if let quantityGrams {
            return "\(Self.formatted(quantityGrams)) g"
        }
        return "1 serving"
    }

    public mutating func setGrams(_ grams: Double) {
        guard baseQuantityGrams != nil, grams.isFinite, grams > 0 else { return }
        quantityGrams = grams
    }

    public mutating func setServingCount(_ count: Double) {
        guard let grams = serving?.grams(forUnitCount: count) else { return }
        quantityGrams = grams
    }

    private static func formatted(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        if abs(value.rounded() - value) < 0.0001 { return String(format: "%.0f", value) }
        return String(format: "%.1f", value)
    }
}

public struct NutritionPlate: Codable, Equatable, Sendable {
    public var items: [NutritionPlateItem]
    public var meal: NutritionMeal

    public init(items: [NutritionPlateItem] = [], meal: NutritionMeal = .breakfast) {
        self.items = items
        self.meal = meal
    }

    public var macros: NutritionMacros {
        items.reduce(.zero) { $0 + $1.macros }
    }

    public mutating func add(_ item: NutritionPlateItem) {
        guard item.isValid else { return }
        items.append(item)
    }

    public mutating func remove(id: UUID) {
        items.removeAll { $0.id == id }
    }

    public mutating func replace(_ item: NutritionPlateItem) {
        guard item.isValid, let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index] = item
    }

    public mutating func setGrams(_ grams: Double, for id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].setGrams(grams)
    }
}

public struct NutritionLogEntry: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var foodID: UUID?
    public var localDate: String
    public var meal: NutritionMeal
    public var name: String
    public var brand: String?
    public var source: NutritionSource
    public var barcode: String?
    public var quantityGrams: Double?
    public var serving: NutritionServing?
    public var macros: NutritionMacros
    public var loggedAt: Date

    public init(
        id: UUID = UUID(),
        foodID: UUID? = nil,
        localDate: String,
        meal: NutritionMeal,
        name: String,
        brand: String? = nil,
        source: NutritionSource,
        barcode: String? = nil,
        quantityGrams: Double? = nil,
        serving: NutritionServing? = nil,
        macros: NutritionMacros,
        loggedAt: Date = Date()
    ) {
        self.id = id
        self.foodID = foodID
        self.localDate = localDate
        self.meal = meal
        self.name = name
        self.brand = brand
        self.source = source
        self.barcode = barcode
        self.quantityGrams = quantityGrams
        self.serving = serving
        self.macros = macros
        self.loggedAt = loggedAt
    }

    public init(item: NutritionPlateItem, localDate: String, meal: NutritionMeal, loggedAt: Date = Date()) {
        self.init(
            foodID: item.foodID,
            localDate: localDate,
            meal: meal,
            name: item.name,
            brand: item.brand,
            source: item.source,
            barcode: item.barcode,
            quantityGrams: item.quantityGrams,
            serving: item.serving,
            macros: item.macros,
            loggedAt: loggedAt
        )
    }

    public func scaled(toGrams grams: Double) -> NutritionLogEntry {
        guard let quantityGrams,
              quantityGrams > 0,
              grams.isFinite,
              grams > 0 else { return self }
        var copy = self
        copy.quantityGrams = grams
        copy.macros = macros.scaled(by: grams / quantityGrams)
        return copy
    }

    public var quantityDescription: String {
        NutritionPlateItem(
            name: name,
            source: source,
            baseMacros: macros,
            baseQuantityGrams: quantityGrams,
            quantityGrams: quantityGrams,
            serving: serving
        ).quantityDescription
    }
}

public struct NutritionDaySummary: Equatable, Sendable {
    public var localDate: String
    public var entries: [NutritionLogEntry]

    public init(localDate: String, entries: [NutritionLogEntry]) {
        self.localDate = localDate
        self.entries = entries
    }

    public var macros: NutritionMacros {
        entries.reduce(.zero) { $0 + $1.macros }
    }

    public func entries(for meal: NutritionMeal) -> [NutritionLogEntry] {
        entries.filter { $0.meal == meal }
    }

    public func macros(for meal: NutritionMeal) -> NutritionMacros {
        entries(for: meal).reduce(.zero) { $0 + $1.macros }
    }
}

public enum NutritionLocalDate {
    public static func key(for date: Date, calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    public static func isValid(_ value: String, calendar: Calendar = Calendar(identifier: .gregorian)) -> Bool {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4,
              parts[1].count == 2,
              parts[2].count == 2,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]),
              let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else {
            return false
        }
        let result = calendar.dateComponents([.year, .month, .day], from: date)
        return result.year == year && result.month == month && result.day == day
    }
}
