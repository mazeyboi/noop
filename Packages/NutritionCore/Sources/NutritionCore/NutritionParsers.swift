import Foundation

public enum GeminiNutritionParserError: Error, Equatable {
    case malformedResponse
    case noUsableFoods
}

public enum GeminiNutritionParser {
    private struct Envelope: Decodable {
        struct Candidate: Decodable {
            struct Content: Decodable {
                struct Part: Decodable { let text: String? }
                let parts: [Part]
            }
            let content: Content?
        }
        let candidates: [Candidate]?
    }

    private struct Payload: Decodable {
        struct Food: Decodable {
            let name: String?
            let grams: Double?
            let calories: Double?
            let protein: Double?
            let carbohydrates: Double?
            let fat: Double?
        }
        let foods: [Food]
    }

    public static func parseResponse(_ data: Data) throws -> [NutritionPlateItem] {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              let text = envelope.candidates?.first?.content?.parts.compactMap(\.text).joined(),
              !text.isEmpty else {
            throw GeminiNutritionParserError.malformedResponse
        }
        let cleaned = stripCodeFence(text)
        guard let payloadData = cleaned.data(using: .utf8),
              let payload = try? JSONDecoder().decode(Payload.self, from: payloadData) else {
            throw GeminiNutritionParserError.malformedResponse
        }

        let items = payload.foods.prefix(30).compactMap { row -> NutritionPlateItem? in
            let name = row.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !name.isEmpty,
                  name.count <= 200,
                  let grams = row.grams,
                  grams.isFinite,
                  grams > 0,
                  let calories = row.calories,
                  let protein = row.protein,
                  let carbohydrates = row.carbohydrates,
                  let fat = row.fat else { return nil }
            let macros = NutritionMacros(
                calories: calories,
                protein: protein,
                carbohydrates: carbohydrates,
                fat: fat
            )
            guard macros.isValid else { return nil }
            return .estimate(name: name, grams: grams, macros: macros)
        }
        guard !items.isEmpty else { throw GeminiNutritionParserError.noUsableFoods }
        return items
    }

    private static func stripCodeFence(_ value: String) -> String {
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.hasPrefix("```") else { return result }
        if let firstLine = result.firstIndex(of: "\n") {
            result = String(result[result.index(after: firstLine)...])
        }
        if result.hasSuffix("```") { result.removeLast(3) }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum OpenFoodFactsError: Error, Equatable {
    case malformedResponse
    case productNotFound
    case malformedNutrition
}

public enum OpenFoodFactsNormalizer {
    public static func food(from data: Data, barcode: String) throws -> NutritionFood {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = number(root["status"]) else {
            throw OpenFoodFactsError.malformedResponse
        }
        guard Int(status) == 1 else { throw OpenFoodFactsError.productNotFound }
        guard let product = root["product"] as? [String: Any],
              let rawName = product["product_name"] as? String else {
            throw OpenFoodFactsError.malformedResponse
        }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 200,
              let nutrients = product["nutriments"] as? [String: Any] else {
            throw OpenFoodFactsError.malformedResponse
        }

        let calories = try requiredNutritionNumber("energy-kcal_100g", in: nutrients)
        let protein = try requiredNutritionNumber("proteins_100g", in: nutrients)
        let carbohydrates = try requiredNutritionNumber("carbohydrates_100g", in: nutrients)
        let fat = try requiredNutritionNumber("fat_100g", in: nutrients)
        let macros = NutritionMacros(
            calories: calories,
            protein: protein,
            carbohydrates: carbohydrates,
            fat: fat
        )
        guard macros.isValid else { throw OpenFoodFactsError.malformedNutrition }

        let servingText = product["serving_size"] as? String
        let servingQuantity = number(product["serving_quantity"])
        let serving = servingText.flatMap(NutritionServingParser.parse)
            ?? servingQuantity.flatMap { value in
                value > 0 ? NutritionServing(
                    amount: 1,
                    unitSingular: "serving",
                    unitPlural: "servings",
                    grams: value
                ) : nil
            }
        let brand = (product["brands"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

        return NutritionFood(
            name: name,
            brand: brand?.isEmpty == false ? brand : nil,
            nutrientsPer100Grams: macros,
            serving: serving,
            source: .openFoodFacts,
            barcode: barcode
        )
    }

    private static func requiredNutritionNumber(_ key: String, in values: [String: Any]) throws -> Double {
        guard values[key] != nil, let value = number(values[key]), value.isFinite, value >= 0 else {
            throw OpenFoodFactsError.malformedNutrition
        }
        return value
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }
}

public enum NutritionServingParser {
    public static func parse(_ value: String) -> NutritionServing? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let captures = captures(
            pattern: #"^([0-9]+(?:\.[0-9]+)?)\s+([A-Za-z]+).*?\(\s*([0-9]+(?:\.[0-9]+)?)\s*g\s*\)"#,
            in: trimmed
        ), captures.count == 3,
           let amount = Double(captures[0]),
           let grams = Double(captures[2]),
           amount > 0,
           grams > 0 {
            let plural = captures[1].lowercased()
            return NutritionServing(
                amount: amount,
                unitSingular: singular(plural),
                unitPlural: plural,
                grams: grams
            )
        }

        if let captures = captures(
            pattern: #"^([0-9]+(?:\.[0-9]+)?)\s*(?:g|gram|grams)$"#,
            in: trimmed
        ), captures.count == 1,
           let grams = Double(captures[0]),
           grams > 0 {
            return NutritionServing(
                amount: 1,
                unitSingular: "serving",
                unitPlural: "servings",
                grams: grams
            )
        }
        return nil
    }

    private static func captures(pattern: String, in value: String) -> [String]? {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(value.startIndex..., in: value)
        guard let match = expression.firstMatch(in: value, range: range), match.range.location != NSNotFound else {
            return nil
        }
        return (1..<match.numberOfRanges).compactMap { index in
            guard let range = Range(match.range(at: index), in: value) else { return nil }
            return String(value[range])
        }
    }

    private static func singular(_ plural: String) -> String {
        if plural.hasSuffix("ies"), plural.count > 3 { return String(plural.dropLast(3)) + "y" }
        if plural.hasSuffix("s"), plural.count > 1 { return String(plural.dropLast()) }
        return plural
    }
}
