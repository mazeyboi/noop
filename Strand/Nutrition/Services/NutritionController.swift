import Combine
import Foundation
import NutritionCore

@MainActor
final class NutritionController: ObservableObject {
    @Published private(set) var summary: NutritionDaySummary
    @Published private(set) var favourites: [NutritionFood] = []
    @Published private(set) var recents: [NutritionFood] = []
    @Published private(set) var frequent: [NutritionFood] = []
    @Published private(set) var library: [NutritionFood] = []
    @Published private(set) var revision = 0
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    private(set) var database: NutritionDatabase?

    init(now: Date = Date()) {
        let day = NutritionLocalDate.key(for: now)
        summary = NutritionDaySummary(localDate: day, entries: [])
        database = nil
        do {
            database = try NutritionDatabase(path: NutritionStorePaths.defaultDatabasePath())
        } catch {
            errorMessage = "Nutrition storage could not be opened. Your other NOOP data is unaffected."
        }
    }

    func reload(localDate: String) async {
        guard let database else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            async let summary = database.daySummary(localDate: localDate)
            async let favourites = database.favouriteFoods(limit: 12)
            async let recents = database.recentFoods(limit: 12)
            async let frequent = database.frequentFoods(limit: 12)
            async let library = database.searchFoods("", limit: 200)
            self.summary = try await summary
            self.favourites = try await favourites
            self.recents = try await recents
            self.frequent = try await frequent
            self.library = try await library
            revision += 1
            errorMessage = nil
        } catch {
            errorMessage = "Nutrition data could not be loaded."
        }
    }

    func search(_ query: String) async -> [NutritionFood] {
        guard let database else { return [] }
        do {
            return try await database.searchFoods(query, limit: 50)
        } catch {
            errorMessage = "The food library could not be searched."
            return []
        }
    }

    func lastQuantity(for food: NutritionFood) async -> Double? {
        guard let database else { return nil }
        return try? await database.lastQuantityGrams(foodID: food.id)
    }

    func food(barcode: String) async -> NutritionFood? {
        guard let database else { return nil }
        return try? await database.food(barcode: barcode)
    }

    @discardableResult
    func saveFood(_ food: NutritionFood, localDate: String) async -> Bool {
        guard let database else { return false }
        do {
            try await database.saveFood(food)
            await reload(localDate: localDate)
            return true
        } catch {
            errorMessage = "The food could not be saved. Check its nutrition and serving values."
            return false
        }
    }

    func deleteFood(_ food: NutritionFood, localDate: String) async {
        guard let database else { return }
        do {
            try await database.deleteFood(id: food.id)
            await reload(localDate: localDate)
        } catch {
            errorMessage = "The custom food could not be deleted."
        }
    }

    func setFavourite(_ food: NutritionFood, isFavourite: Bool, localDate: String) async {
        guard let database else { return }
        do {
            try await database.setFavourite(foodID: food.id, isFavourite: isFavourite)
            await reload(localDate: localDate)
        } catch {
            errorMessage = "The favourite could not be updated."
        }
    }

    @discardableResult
    func log(_ plate: NutritionPlate, localDate: String) async -> Bool {
        guard let database else { return false }
        do {
            _ = try await database.log(plate: plate, localDate: localDate)
            await reload(localDate: localDate)
            return true
        } catch {
            errorMessage = "The foods could not be logged. Nothing was added."
            return false
        }
    }

    func update(_ entry: NutritionLogEntry) async {
        guard let database else { return }
        do {
            try await database.updateEntry(entry)
            await reload(localDate: entry.localDate)
        } catch {
            errorMessage = "The food entry could not be updated."
        }
    }

    func duplicate(_ entry: NutritionLogEntry) async {
        guard let database else { return }
        do {
            _ = try await database.duplicateEntry(id: entry.id)
            await reload(localDate: entry.localDate)
        } catch {
            errorMessage = "The food entry could not be duplicated."
        }
    }

    func delete(_ entry: NutritionLogEntry) async -> NutritionLogEntry? {
        guard let database else { return nil }
        do {
            let deleted = try await database.deleteEntry(id: entry.id)
            await reload(localDate: entry.localDate)
            return deleted
        } catch {
            errorMessage = "The food entry could not be deleted."
            return nil
        }
    }

    func restore(_ entry: NutritionLogEntry) async {
        guard let database else { return }
        do {
            try await database.restoreEntry(entry)
            await reload(localDate: entry.localDate)
        } catch {
            errorMessage = "The deleted food could not be restored."
        }
    }
}

enum NutritionStorePaths {
    static func defaultDatabasePath() throws -> String {
        let fileManager = FileManager.default
        let appSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = appSupport.appendingPathComponent("OpenWhoop/Nutrition", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = directory.appendingPathComponent("nutrition.sqlite")

        #if os(iOS)
        let protection: [FileAttributeKey: Any] = [
            .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
        ]
        try? fileManager.setAttributes(protection, ofItemAtPath: directory.path)
        for suffix in ["", "-wal", "-shm"] {
            let path = database.path + suffix
            if fileManager.fileExists(atPath: path) {
                try? fileManager.setAttributes(protection, ofItemAtPath: path)
            }
        }
        #endif

        return database.path
    }
}
