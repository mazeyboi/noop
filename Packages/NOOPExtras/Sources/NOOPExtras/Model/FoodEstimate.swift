import Foundation

/// What an AI provider returns for one meal photo. Every provider adapter produces this same shape.
public struct FoodEstimate: Codable, Equatable, Sendable {
    public enum Confidence: String, Codable, Sendable { case low, medium, high }

    public struct Item: Codable, Equatable, Sendable {
        public var name: String
        public var grams: Double
        public var kcal: Double
        public var proteinG: Double
        public var carbsG: Double
        public var fatG: Double
        public var fiberG: Double
        public var caffeineMg: Double
        public var alcoholG: Double

        public init(name: String, grams: Double, kcal: Double, proteinG: Double = 0, carbsG: Double = 0,
                    fatG: Double = 0, fiberG: Double = 0, caffeineMg: Double = 0, alcoholG: Double = 0) {
            self.name = name; self.grams = grams; self.kcal = kcal; self.proteinG = proteinG
            self.carbsG = carbsG; self.fatG = fatG; self.fiberG = fiberG
            self.caffeineMg = caffeineMg; self.alcoholG = alcoholG
        }

        public var nutrients: Nutrients {
            Nutrients(kcal: kcal, proteinG: proteinG, carbsG: carbsG, fatG: fatG, fiberG: fiberG,
                      caffeineMg: caffeineMg, alcoholG: alcoholG)
        }

        public var entryItem: EntryItem { EntryItem(name: name, grams: grams, nutrients: nutrients) }
    }

    public var items: [Item]
    public var confidence: Confidence
    public var note: String

    public init(items: [Item], confidence: Confidence, note: String) {
        self.items = items; self.confidence = confidence; self.note = note
    }

    /// Totals are always recomputed from the items; a model's own "total" is never trusted.
    public var totals: Nutrients { items.reduce(.zero) { $0 + $1.nutrients } }
}
