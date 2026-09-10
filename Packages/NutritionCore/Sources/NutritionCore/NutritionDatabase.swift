import Foundation
import GRDB

public enum NutritionDatabaseError: Error, Equatable {
    case invalidFood
    case invalidEntry
    case invalidLocalDate
    case emptyPlate
    case entryNotFound
    case corruptRecord
}

public actor NutritionDatabase {
    private let dbWriter: any DatabaseWriter

    public init(path: String) throws {
        var configuration = Configuration()
        configuration.busyMode = .timeout(5)
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
        }
        let pool = try DatabasePool(path: path, configuration: configuration)
        try Self.migrator.migrate(pool)
        dbWriter = pool
    }

    private init(dbWriter: any DatabaseWriter) throws {
        try Self.migrator.migrate(dbWriter)
        self.dbWriter = dbWriter
    }

    public static func inMemory() throws -> NutritionDatabase {
        try NutritionDatabase(dbWriter: DatabaseQueue())
    }

    func tableNamesForTesting() throws -> Set<String> {
        try dbWriter.read { db in
            try Set(String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'"))
        }
    }

    func columnNamesForTesting(table: String) throws -> [String] {
        try dbWriter.read { db in try db.columns(in: table).map(\.name) }
    }

    public func saveFood(_ food: NutritionFood) throws {
        guard food.isValid else { throw NutritionDatabaseError.invalidFood }
        try dbWriter.write { db in
            try db.execute(sql: """
                INSERT INTO nutritionFood (
                    id, name, brand, caloriesPer100g, proteinPer100g, carbohydratesPer100g, fatPer100g,
                    servingAmount, servingUnitSingular, servingUnitPlural, servingGrams,
                    source, barcode, isFavourite, createdAt, updatedAt
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    name = excluded.name,
                    brand = excluded.brand,
                    caloriesPer100g = excluded.caloriesPer100g,
                    proteinPer100g = excluded.proteinPer100g,
                    carbohydratesPer100g = excluded.carbohydratesPer100g,
                    fatPer100g = excluded.fatPer100g,
                    servingAmount = excluded.servingAmount,
                    servingUnitSingular = excluded.servingUnitSingular,
                    servingUnitPlural = excluded.servingUnitPlural,
                    servingGrams = excluded.servingGrams,
                    source = excluded.source,
                    barcode = excluded.barcode,
                    isFavourite = excluded.isFavourite,
                    updatedAt = excluded.updatedAt
                """, arguments: foodArguments(food))
        }
    }

    public func food(id: UUID) throws -> NutritionFood? {
        try dbWriter.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM nutritionFood WHERE id = ?", arguments: [id.uuidString])
                .map(decodeFood)
        }
    }

    public func food(barcode: String) throws -> NutritionFood? {
        try dbWriter.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM nutritionFood WHERE barcode = ?", arguments: [barcode])
                .map(decodeFood)
        }
    }

    public func searchFoods(_ query: String, limit: Int = 50) throws -> [NutritionFood] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return try dbWriter.read { db in
            let rows: [Row]
            if trimmed.isEmpty {
                rows = try Row.fetchAll(db, sql: """
                    SELECT * FROM nutritionFood
                    ORDER BY isFavourite DESC, name COLLATE NOCASE, brand COLLATE NOCASE
                    LIMIT ?
                    """, arguments: [max(1, limit)])
            } else {
                let pattern = "%\(escapeLike(trimmed.lowercased()))%"
                rows = try Row.fetchAll(db, sql: """
                    SELECT * FROM nutritionFood
                    WHERE lower(name) LIKE ? ESCAPE '\\'
                       OR lower(COALESCE(brand, '')) LIKE ? ESCAPE '\\'
                       OR barcode = ?
                    ORDER BY isFavourite DESC, name COLLATE NOCASE, brand COLLATE NOCASE
                    LIMIT ?
                    """, arguments: [pattern, pattern, trimmed, max(1, limit)])
            }
            return try rows.map(decodeFood)
        }
    }

    public func favouriteFoods(limit: Int = 50) throws -> [NutritionFood] {
        try dbWriter.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM nutritionFood
                WHERE isFavourite = 1
                ORDER BY name COLLATE NOCASE
                LIMIT ?
                """, arguments: [max(1, limit)]).map(decodeFood)
        }
    }

    public func setFavourite(foodID: UUID, isFavourite: Bool) throws {
        try dbWriter.write { db in
            try db.execute(
                sql: "UPDATE nutritionFood SET isFavourite = ?, updatedAt = ? WHERE id = ?",
                arguments: [isFavourite, Date().timeIntervalSince1970, foodID.uuidString]
            )
        }
    }

    public func deleteFood(id: UUID) throws {
        try dbWriter.write { db in
            try db.execute(sql: "DELETE FROM nutritionFood WHERE id = ?", arguments: [id.uuidString])
        }
    }

    @discardableResult
    public func log(
        plate: NutritionPlate,
        localDate: String,
        loggedAt: Date = Date()
    ) throws -> [NutritionLogEntry] {
        guard NutritionLocalDate.isValid(localDate) else { throw NutritionDatabaseError.invalidLocalDate }
        guard !plate.items.isEmpty else { throw NutritionDatabaseError.emptyPlate }
        guard plate.items.allSatisfy(\.isValid) else { throw NutritionDatabaseError.invalidEntry }
        let entries = plate.items.enumerated().map { index, item in
            NutritionLogEntry(
                item: item,
                localDate: localDate,
                meal: plate.meal,
                loggedAt: loggedAt.addingTimeInterval(Double(index) / 1000)
            )
        }
        try dbWriter.write { db in
            for entry in entries { try insertEntry(entry, db: db) }
        }
        return entries
    }

    public func daySummary(localDate: String) throws -> NutritionDaySummary {
        guard NutritionLocalDate.isValid(localDate) else { throw NutritionDatabaseError.invalidLocalDate }
        return try dbWriter.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT * FROM nutritionLogEntry
                WHERE localDate = ?
                ORDER BY loggedAt, id
                """, arguments: [localDate])
            return NutritionDaySummary(localDate: localDate, entries: try rows.map(decodeEntry))
        }
    }

    public func updateEntry(_ entry: NutritionLogEntry) throws {
        guard entryIsValid(entry) else { throw NutritionDatabaseError.invalidEntry }
        try dbWriter.write { db in
            try db.execute(sql: """
                UPDATE nutritionLogEntry SET
                    foodId = ?, localDate = ?, meal = ?, name = ?, brand = ?, source = ?, barcode = ?,
                    quantityGrams = ?, servingAmount = ?, servingUnitSingular = ?, servingUnitPlural = ?,
                    servingGrams = ?, calories = ?, protein = ?, carbohydrates = ?, fat = ?, loggedAt = ?
                WHERE id = ?
                """, arguments: entryUpdateArguments(entry))
            guard db.changesCount == 1 else { throw NutritionDatabaseError.entryNotFound }
        }
    }

    public func duplicateEntry(id: UUID, loggedAt: Date = Date()) throws -> NutritionLogEntry {
        guard let entry = try entry(id: id) else { throw NutritionDatabaseError.entryNotFound }
        let duplicate = NutritionLogEntry(
            foodID: entry.foodID,
            localDate: entry.localDate,
            meal: entry.meal,
            name: entry.name,
            brand: entry.brand,
            source: entry.source,
            barcode: entry.barcode,
            quantityGrams: entry.quantityGrams,
            serving: entry.serving,
            macros: entry.macros,
            loggedAt: loggedAt
        )
        try dbWriter.write { db in try insertEntry(duplicate, db: db) }
        return duplicate
    }

    @discardableResult
    public func deleteEntry(id: UUID) throws -> NutritionLogEntry? {
        try dbWriter.write { db in
            let entry = try Row.fetchOne(
                db,
                sql: "SELECT * FROM nutritionLogEntry WHERE id = ?",
                arguments: [id.uuidString]
            ).map(decodeEntry)
            try db.execute(sql: "DELETE FROM nutritionLogEntry WHERE id = ?", arguments: [id.uuidString])
            return entry
        }
    }

    public func restoreEntry(_ entry: NutritionLogEntry) throws {
        guard entryIsValid(entry) else { throw NutritionDatabaseError.invalidEntry }
        try dbWriter.write { db in try insertEntry(entry, db: db) }
    }

    public func recentFoods(limit: Int = 12) throws -> [NutritionFood] {
        try rankedFoods(orderBy: "MAX(e.loggedAt) DESC", limit: limit)
    }

    public func frequentFoods(limit: Int = 12) throws -> [NutritionFood] {
        try rankedFoods(orderBy: "COUNT(*) DESC, MAX(e.loggedAt) DESC", limit: limit)
    }

    public func lastQuantityGrams(foodID: UUID) throws -> Double? {
        try dbWriter.read { db in
            try Double.fetchOne(db, sql: """
                SELECT quantityGrams FROM nutritionLogEntry
                WHERE foodId = ? AND quantityGrams IS NOT NULL
                ORDER BY loggedAt DESC LIMIT 1
                """, arguments: [foodID.uuidString])
        }
    }

    private func entry(id: UUID) throws -> NutritionLogEntry? {
        try dbWriter.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM nutritionLogEntry WHERE id = ?", arguments: [id.uuidString])
                .map(decodeEntry)
        }
    }

    private func rankedFoods(orderBy: String, limit: Int) throws -> [NutritionFood] {
        try dbWriter.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT f.* FROM nutritionFood f
                JOIN nutritionLogEntry e ON e.foodId = f.id
                GROUP BY f.id
                ORDER BY \(orderBy)
                LIMIT ?
                """, arguments: [max(1, limit)])
            return try rows.map(decodeFood)
        }
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1-nutrition") { db in
            try db.execute(sql: """
                CREATE TABLE nutritionFood (
                    id TEXT PRIMARY KEY NOT NULL,
                    name TEXT NOT NULL,
                    brand TEXT,
                    caloriesPer100g DOUBLE NOT NULL CHECK (caloriesPer100g >= 0),
                    proteinPer100g DOUBLE NOT NULL CHECK (proteinPer100g >= 0),
                    carbohydratesPer100g DOUBLE NOT NULL CHECK (carbohydratesPer100g >= 0),
                    fatPer100g DOUBLE NOT NULL CHECK (fatPer100g >= 0),
                    servingAmount DOUBLE,
                    servingUnitSingular TEXT,
                    servingUnitPlural TEXT,
                    servingGrams DOUBLE,
                    source TEXT NOT NULL,
                    barcode TEXT,
                    isFavourite INTEGER NOT NULL DEFAULT 0,
                    createdAt DOUBLE NOT NULL,
                    updatedAt DOUBLE NOT NULL
                );
                CREATE UNIQUE INDEX nutritionFood_barcode ON nutritionFood(barcode) WHERE barcode IS NOT NULL;
                CREATE INDEX nutritionFood_name ON nutritionFood(name COLLATE NOCASE);

                CREATE TABLE nutritionLogEntry (
                    id TEXT PRIMARY KEY NOT NULL,
                    foodId TEXT REFERENCES nutritionFood(id) ON DELETE SET NULL,
                    localDate TEXT NOT NULL,
                    meal TEXT NOT NULL,
                    name TEXT NOT NULL,
                    brand TEXT,
                    source TEXT NOT NULL,
                    barcode TEXT,
                    quantityGrams DOUBLE,
                    servingAmount DOUBLE,
                    servingUnitSingular TEXT,
                    servingUnitPlural TEXT,
                    servingGrams DOUBLE,
                    calories DOUBLE NOT NULL CHECK (calories >= 0),
                    protein DOUBLE NOT NULL CHECK (protein >= 0),
                    carbohydrates DOUBLE NOT NULL CHECK (carbohydrates >= 0),
                    fat DOUBLE NOT NULL CHECK (fat >= 0),
                    loggedAt DOUBLE NOT NULL
                );
                CREATE INDEX nutritionLogEntry_day_meal ON nutritionLogEntry(localDate, meal, loggedAt);
                CREATE INDEX nutritionLogEntry_food_recent ON nutritionLogEntry(foodId, loggedAt DESC);
                """)
        }
        return migrator
    }
}

private func foodArguments(_ food: NutritionFood) -> StatementArguments {
    [
        food.id.uuidString,
        food.name.trimmingCharacters(in: .whitespacesAndNewlines),
        normalizedOptional(food.brand),
        food.nutrientsPer100Grams.calories,
        food.nutrientsPer100Grams.protein,
        food.nutrientsPer100Grams.carbohydrates,
        food.nutrientsPer100Grams.fat,
        food.serving?.amount,
        food.serving?.unitSingular,
        food.serving?.unitPlural,
        food.serving?.grams,
        food.source.rawValue,
        normalizedOptional(food.barcode),
        food.isFavourite,
        food.createdAt.timeIntervalSince1970,
        food.updatedAt.timeIntervalSince1970,
    ]
}

private func entryUpdateArguments(_ entry: NutritionLogEntry) -> StatementArguments {
    entryArguments(entry, includeIDFirst: false) + [entry.id.uuidString]
}

private func entryArguments(_ entry: NutritionLogEntry, includeIDFirst: Bool = true) -> StatementArguments {
    var values: [DatabaseValueConvertible?] = []
    if includeIDFirst { values.append(entry.id.uuidString) }
    values.append(contentsOf: [
        entry.foodID?.uuidString,
        entry.localDate,
        entry.meal.rawValue,
        entry.name.trimmingCharacters(in: .whitespacesAndNewlines),
        normalizedOptional(entry.brand),
        entry.source.rawValue,
        normalizedOptional(entry.barcode),
        entry.quantityGrams,
        entry.serving?.amount,
        entry.serving?.unitSingular,
        entry.serving?.unitPlural,
        entry.serving?.grams,
        entry.macros.calories,
        entry.macros.protein,
        entry.macros.carbohydrates,
        entry.macros.fat,
        entry.loggedAt.timeIntervalSince1970,
    ])
    return StatementArguments(values)
}

private func insertEntry(_ entry: NutritionLogEntry, db: Database) throws {
    guard entryIsValid(entry) else { throw NutritionDatabaseError.invalidEntry }
    try db.execute(sql: """
        INSERT INTO nutritionLogEntry (
            id, foodId, localDate, meal, name, brand, source, barcode, quantityGrams,
            servingAmount, servingUnitSingular, servingUnitPlural, servingGrams,
            calories, protein, carbohydrates, fat, loggedAt
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, arguments: entryArguments(entry))
}

private func entryIsValid(_ entry: NutritionLogEntry) -> Bool {
    let quantityIsValid = entry.quantityGrams.map { $0.isFinite && $0 > 0 } ?? true
    return NutritionLocalDate.isValid(entry.localDate)
        && !entry.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && entry.name.count <= 200
        && entry.macros.isValid
        && quantityIsValid
        && (entry.serving == nil || entry.serving?.isValid == true)
}

private func decodeFood(_ row: Row) throws -> NutritionFood {
    guard let id = UUID(uuidString: row["id"]),
          let source = NutritionSource(rawValue: row["source"]) else {
        throw NutritionDatabaseError.corruptRecord
    }
    return NutritionFood(
        id: id,
        name: row["name"],
        brand: row["brand"],
        nutrientsPer100Grams: NutritionMacros(
            calories: row["caloriesPer100g"],
            protein: row["proteinPer100g"],
            carbohydrates: row["carbohydratesPer100g"],
            fat: row["fatPer100g"]
        ),
        serving: decodeServing(row),
        source: source,
        barcode: row["barcode"],
        isFavourite: row["isFavourite"],
        createdAt: Date(timeIntervalSince1970: row["createdAt"]),
        updatedAt: Date(timeIntervalSince1970: row["updatedAt"])
    )
}

private func decodeEntry(_ row: Row) throws -> NutritionLogEntry {
    guard let id = UUID(uuidString: row["id"]),
          let meal = NutritionMeal(rawValue: row["meal"]),
          let source = NutritionSource(rawValue: row["source"]) else {
        throw NutritionDatabaseError.corruptRecord
    }
    let foodIDString: String? = row["foodId"]
    return NutritionLogEntry(
        id: id,
        foodID: foodIDString.flatMap(UUID.init(uuidString:)),
        localDate: row["localDate"],
        meal: meal,
        name: row["name"],
        brand: row["brand"],
        source: source,
        barcode: row["barcode"],
        quantityGrams: row["quantityGrams"],
        serving: decodeServing(row),
        macros: NutritionMacros(
            calories: row["calories"],
            protein: row["protein"],
            carbohydrates: row["carbohydrates"],
            fat: row["fat"]
        ),
        loggedAt: Date(timeIntervalSince1970: row["loggedAt"])
    )
}

private func decodeServing(_ row: Row) -> NutritionServing? {
    let amount: Double? = row["servingAmount"]
    let singular: String? = row["servingUnitSingular"]
    let plural: String? = row["servingUnitPlural"]
    let grams: Double? = row["servingGrams"]
    guard let amount, let singular, let plural, let grams else { return nil }
    let serving = NutritionServing(amount: amount, unitSingular: singular, unitPlural: plural, grams: grams)
    return serving.isValid ? serving : nil
}

private func normalizedOptional(_ value: String?) -> String? {
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed?.isEmpty == false ? trimmed : nil
}

private func escapeLike(_ value: String) -> String {
    value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "%", with: "\\%")
        .replacingOccurrences(of: "_", with: "\\_")
}
