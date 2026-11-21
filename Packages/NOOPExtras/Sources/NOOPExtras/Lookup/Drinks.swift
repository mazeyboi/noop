import Foundation

/// One-tap drinks (caffeine and alcohol), editable in Food settings.
public struct DrinkPreset: Codable, Equatable, Identifiable, Sendable {
    public var id: String { name }
    public var name: String
    public var ml: Double
    public var kcal: Double
    public var caffeineMg: Double
    public var alcoholG: Double
    public var carbsG: Double

    public init(name: String, ml: Double, kcal: Double, caffeineMg: Double = 0, alcoholG: Double = 0, carbsG: Double = 0) {
        self.name = name; self.ml = ml; self.kcal = kcal
        self.caffeineMg = caffeineMg; self.alcoholG = alcoholG; self.carbsG = carbsG
    }

    /// Alcohol grams for a volume and % ABV (ethanol density 0.789 g/ml).
    public static func alcoholGrams(ml: Double, abv: Double) -> Double { ml * abv / 100 * 0.789 }

    public func entry(at: Date, meal: MealType) -> FoodEntry {
        FoodEntry.new(at: at, meal: meal, method: .quick_add, items: [
            EntryItem(name: name, grams: ml,
                      nutrients: Nutrients(kcal: kcal, carbsG: carbsG, caffeineMg: caffeineMg, alcoholG: alcoholG)),
        ])
    }
}

public enum Drinks {
    public static let defaults: [DrinkPreset] = [
        DrinkPreset(name: "Coffee", ml: 240, kcal: 2, caffeineMg: 95),
        DrinkPreset(name: "Espresso", ml: 30, kcal: 1, caffeineMg: 63),
        DrinkPreset(name: "Energy drink", ml: 250, kcal: 115, caffeineMg: 80, carbsG: 28),
        DrinkPreset(name: "Beer", ml: 330, kcal: 142, alcoholG: DrinkPreset.alcoholGrams(ml: 330, abv: 4.6), carbsG: 11),
        DrinkPreset(name: "Wine", ml: 150, kcal: 125, alcoholG: DrinkPreset.alcoholGrams(ml: 150, abv: 12), carbsG: 4),
    ]

    static let kvKey = "drinks.presets"

    public static func load(store: ExtrasStore) -> [DrinkPreset] {
        guard let json = try? store.kv(kvKey),
              let presets = try? JSONDecoder().decode([DrinkPreset].self, from: Data(json.utf8)), !presets.isEmpty
        else { return defaults }
        return presets
    }

    public static func save(_ presets: [DrinkPreset], store: ExtrasStore) throws {
        try store.setKV(kvKey, String(decoding: try JSONEncoder().encode(presets), as: UTF8.self))
    }
}
