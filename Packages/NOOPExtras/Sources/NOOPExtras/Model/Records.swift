import Foundation

public enum MealType: String, Codable, CaseIterable, Sendable, Identifiable {
    case breakfast, lunch, dinner, snack
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }

    /// The meal a log at `date` most likely belongs to (local time).
    public static func suggested(for date: Date, calendar: Calendar = .current) -> MealType {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        let minutes = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        switch minutes {
        case (4 * 60)..<(10 * 60 + 30): return .breakfast
        case (10 * 60 + 30)..<(15 * 60): return .lunch
        case (17 * 60)..<(21 * 60): return .dinner
        default: return .snack
        }
    }
}

/// How an entry was made (synced as `method`; the dashboard uses it to see how often the AI needed fixing).
public enum EntryMethod: String, Codable, CaseIterable, Sendable {
    case photo_ai, barcode, search, quick_add, custom
}

public enum EntryStatus: String, Codable, Sendable {
    /// Counted in the day's totals.
    case logged
    /// A photo waiting for an AI estimate (no provider yet, offline, or a retryable error).
    case pending
    /// The AI refused, or the request can't succeed as it is; needs a tap to retry or manual entry.
    case failed
}

public enum FoodSource: String, Codable, Sendable {
    case off, generic, custom, ai
}

public struct Food: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var brand: String?
    public var barcode: String?
    public var source: FoodSource
    public var per100: Nutrients
    public var servingG: Double?
    public var servingName: String?
    public var favourite: Bool
    public var updatedAt: Date
    public var deleted: Bool

    public init(id: String = UUID().uuidString, name: String, brand: String? = nil, barcode: String? = nil,
                source: FoodSource, per100: Nutrients, servingG: Double? = nil, servingName: String? = nil,
                favourite: Bool = false, updatedAt: Date = Date(), deleted: Bool = false) {
        self.id = id; self.name = name; self.brand = brand; self.barcode = barcode; self.source = source
        self.per100 = per100; self.servingG = servingG; self.servingName = servingName
        self.favourite = favourite; self.updatedAt = updatedAt; self.deleted = deleted
    }

    public var displayName: String {
        [name, brand ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// An entry item for `grams` of this food.
    public func item(grams: Double) -> EntryItem {
        EntryItem(name: name, grams: grams, nutrients: per100.per100(toGrams: grams), foodId: id)
    }
}

public struct EntryItem: Codable, Equatable, Hashable, Sendable {
    public var name: String
    public var grams: Double?
    public var nutrients: Nutrients
    public var foodId: String?

    public init(name: String, grams: Double?, nutrients: Nutrients, foodId: String? = nil) {
        self.name = name; self.grams = grams; self.nutrients = nutrients; self.foodId = foodId
    }

    public static func total(_ items: [EntryItem]) -> Nutrients { items.reduce(.zero) { $0 + $1.nutrients } }
}

public struct FoodEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var at: Date
    public var meal: MealType
    public var method: EntryMethod
    public var status: EntryStatus
    public var items: [EntryItem]
    public var photoId: String?
    public var hint: String?
    /// The AI's first estimate, kept unchanged after Oliver edits the entry.
    public var aiOriginal: FoodEstimate?
    public var aiProvider: String?
    public var aiModel: String?
    public var confidence: FoodEstimate.Confidence?
    public var note: String?
    /// True once Oliver changed anything the AI (or a lookup) filled in. His edits always win.
    public var edited: Bool
    public var error: String?
    public var attempts: Int
    public var updatedAt: Date
    public var deleted: Bool

    /// Always the sum of the items.
    public var totals: Nutrients { EntryItem.total(items) }

    public static func new(id: String = UUID().uuidString, at: Date, meal: MealType, method: EntryMethod,
                           status: EntryStatus = .logged, items: [EntryItem] = []) -> FoodEntry {
        FoodEntry(id: id, at: at, meal: meal, method: method, status: status, items: items, photoId: nil,
                  hint: nil, aiOriginal: nil, aiProvider: nil, aiModel: nil, confidence: nil, note: nil,
                  edited: false, error: nil, attempts: 0, updatedAt: at, deleted: false)
    }

    public var title: String {
        if items.isEmpty { return status == .logged ? "Quick add" : "Photo" }
        let names = items.map(\.name)
        return names.count <= 2 ? names.joined(separator: ", ") : "\(names[0]), \(names[1]) +\(names.count - 2)"
    }
}

public struct SavedMeal: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var items: [EntryItem]
    public var updatedAt: Date
    public var deleted: Bool

    public init(id: String = UUID().uuidString, name: String, items: [EntryItem], updatedAt: Date = Date(),
                deleted: Bool = false) {
        self.id = id; self.name = name; self.items = items; self.updatedAt = updatedAt; self.deleted = deleted
    }
}

public struct Targets: Codable, Equatable, Sendable {
    public var kcal: Double
    public var proteinG: Double
    public var carbsG: Double
    public var fatG: Double
    public var fiberG: Double?
    public var caffeineMaxMg: Double?
    public var alcoholMaxG: Double?
    public var updatedAt: Date

    public init(kcal: Double, proteinG: Double, carbsG: Double, fatG: Double, fiberG: Double? = nil,
                caffeineMaxMg: Double? = nil, alcoholMaxG: Double? = nil, updatedAt: Date = Date()) {
        self.kcal = kcal; self.proteinG = proteinG; self.carbsG = carbsG; self.fatG = fatG
        self.fiberG = fiberG; self.caffeineMaxMg = caffeineMaxMg; self.alcoholMaxG = alcoholMaxG
        self.updatedAt = updatedAt
    }
}
