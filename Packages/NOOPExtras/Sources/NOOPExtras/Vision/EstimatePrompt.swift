import Foundation

/// The one prompt and schema every provider uses.
public enum EstimatePrompt {
    public static let system = """
    You estimate the food and drink in a meal photo for a personal calorie log. Your estimate is saved \
    as the log entry, so make it as accurate as you can.

    The person lives in Denmark. Recognise Danish dishes and products (rugbrød, smørrebrød, frikadeller, \
    leverpostej, remoulade, skyr and so on) and use Danish portion sizes when they fit.

    Rules:
    - One item per distinct food or drink. "grams" is the edible amount actually eaten.
    - Estimate realistic portions. When unsure, lean slightly towards more calories, not fewer: \
    under-estimates work against the person's weight-loss goal. Include visible oil, butter, sauces \
    and dressings.
    - The hint, if any, overrides what you see (for example "half eaten", "about 200 g rice", \
    "cooked in butter").
    - caffeine_mg and alcohol_g only for items that contain them, otherwise 0.
    - confidence: "low" when portions or ingredients are hard to judge, "high" only for clear, \
    standard items.
    - note: one short line on your main assumption.
    - If there is no food or drink in the photo, return an empty items list and say what you see in note.
    Answer with the JSON object only.
    """

    public static func userText(_ r: EstimateRequest) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.timeZone = r.timeZone
        f.dateFormat = "EEEE d MMMM yyyy, HH:mm"
        var lines = ["Meal: \(r.meal.rawValue)", "Time: \(f.string(from: r.at)) (\(r.timeZone.identifier))"]
        if let hint = r.hint?.trimmingCharacters(in: .whitespacesAndNewlines), !hint.isEmpty {
            lines.append("Hint from the person: \(hint)")
        }
        lines.append("Estimate this meal.")
        return lines.joined(separator: "\n")
    }

    static let itemFields: [(String, String)] = [
        ("name", "string"), ("grams", "number"), ("kcal", "number"), ("protein_g", "number"),
        ("carbs_g", "number"), ("fat_g", "number"), ("fiber_g", "number"), ("caffeine_mg", "number"),
        ("alcohol_g", "number"),
    ]

    /// Standard JSON Schema (Anthropic `output_config.format`, OpenAI strict `json_schema`).
    public static var jsonSchema: [String: Any] {
        var itemProps: [String: Any] = [:]
        for (name, type) in itemFields { itemProps[name] = ["type": type] }
        return [
            "type": "object",
            "additionalProperties": false,
            "required": ["items", "confidence", "note"],
            "properties": [
                "items": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "additionalProperties": false,
                        "required": itemFields.map(\.0),
                        "properties": itemProps,
                    ] as [String: Any],
                ] as [String: Any],
                "confidence": ["type": "string", "enum": ["low", "medium", "high"]],
                "note": ["type": "string"],
            ] as [String: Any],
        ]
    }

    /// Gemini's OpenAPI-style `responseSchema` (uppercase types, no additionalProperties).
    public static var geminiSchema: [String: Any] {
        var itemProps: [String: Any] = [:]
        for (name, type) in itemFields { itemProps[name] = ["type": type.uppercased()] }
        return [
            "type": "OBJECT",
            "required": ["items", "confidence", "note"],
            "propertyOrdering": ["items", "confidence", "note"],
            "properties": [
                "items": [
                    "type": "ARRAY",
                    "items": ["type": "OBJECT", "required": itemFields.map(\.0),
                              "propertyOrdering": itemFields.map(\.0), "properties": itemProps] as [String: Any],
                ] as [String: Any],
                "confidence": ["type": "STRING", "enum": ["low", "medium", "high"]],
                "note": ["type": "STRING"],
            ] as [String: Any],
        ]
    }
}

extension FoodEstimate {
    /// Reads a model's reply leniently: code fences, prose around the object, snake or camel keys,
    /// numbers as strings, nulls as 0. Totals are recomputed from the items.
    public static func parse(_ text: String) throws -> FoodEstimate {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
              let obj = try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8)) as? [String: Any]
        else { throw ProviderError.malformed("no JSON object in the reply") }

        func num(_ d: [String: Any], _ keys: String...) -> Double {
            for k in keys {
                if let n = d[k] as? NSNumber { return n.doubleValue }
                if let s = d[k] as? String, let n = Double(s.trimmingCharacters(in: .whitespaces)) { return n }
            }
            return 0
        }
        guard let rawItems = obj["items"] as? [[String: Any]] else {
            throw ProviderError.malformed("reply has no items list")
        }
        let items = rawItems.compactMap { d -> Item? in
            guard let name = (d["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty
            else { return nil }
            return Item(name: name, grams: num(d, "grams", "g"), kcal: num(d, "kcal", "calories"),
                        proteinG: num(d, "protein_g", "proteinG", "protein"),
                        carbsG: num(d, "carbs_g", "carbsG", "carbs"),
                        fatG: num(d, "fat_g", "fatG", "fat"),
                        fiberG: num(d, "fiber_g", "fiberG", "fibre_g", "fiber"),
                        caffeineMg: num(d, "caffeine_mg", "caffeineMg", "caffeine"),
                        alcoholG: num(d, "alcohol_g", "alcoholG", "alcohol"))
        }
        let note = (obj["note"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if items.isEmpty {
            throw ProviderError.refused("No food found in the photo." + (note.isEmpty ? "" : " \(note)"))
        }
        let conf = Confidence(rawValue: ((obj["confidence"] as? String) ?? "").lowercased()) ?? .low
        return FoodEstimate(items: items, confidence: conf, note: note)
    }
}
