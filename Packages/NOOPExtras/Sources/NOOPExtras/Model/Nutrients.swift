import Foundation

/// Nutrient amounts. Used both as "per 100 g" values on a food and as absolute amounts on an entry.
public struct Nutrients: Codable, Equatable, Hashable, Sendable {
    public var kcal: Double
    public var proteinG: Double
    public var carbsG: Double
    public var fatG: Double
    public var fiberG: Double
    public var sugarG: Double
    public var saltG: Double
    public var caffeineMg: Double
    public var alcoholG: Double

    public init(kcal: Double = 0, proteinG: Double = 0, carbsG: Double = 0, fatG: Double = 0,
                fiberG: Double = 0, sugarG: Double = 0, saltG: Double = 0,
                caffeineMg: Double = 0, alcoholG: Double = 0) {
        self.kcal = kcal; self.proteinG = proteinG; self.carbsG = carbsG; self.fatG = fatG
        self.fiberG = fiberG; self.sugarG = sugarG; self.saltG = saltG
        self.caffeineMg = caffeineMg; self.alcoholG = alcoholG
    }

    public static let zero = Nutrients()

    public func scaled(by f: Double) -> Nutrients {
        Nutrients(kcal: kcal * f, proteinG: proteinG * f, carbsG: carbsG * f, fatG: fatG * f,
                  fiberG: fiberG * f, sugarG: sugarG * f, saltG: saltG * f,
                  caffeineMg: caffeineMg * f, alcoholG: alcoholG * f)
    }

    /// Treats `self` as per-100 g values and returns the amounts in `grams`.
    public func per100(toGrams grams: Double) -> Nutrients { scaled(by: grams / 100) }

    public static func + (a: Nutrients, b: Nutrients) -> Nutrients {
        Nutrients(kcal: a.kcal + b.kcal, proteinG: a.proteinG + b.proteinG, carbsG: a.carbsG + b.carbsG,
                  fatG: a.fatG + b.fatG, fiberG: a.fiberG + b.fiberG, sugarG: a.sugarG + b.sugarG,
                  saltG: a.saltG + b.saltG, caffeineMg: a.caffeineMg + b.caffeineMg,
                  alcoholG: a.alcoholG + b.alcoholG)
    }

    private enum CodingKeys: String, CodingKey {
        case kcal, proteinG, carbsG, fatG, fiberG, sugarG, saltG, caffeineMg, alcoholG
    }

    // Missing keys decode as 0 so older rows and partial server payloads stay readable.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v(_ k: CodingKeys) -> Double { ((try? c.decodeIfPresent(Double.self, forKey: k)) ?? nil) ?? 0 }
        self.init(kcal: v(.kcal), proteinG: v(.proteinG), carbsG: v(.carbsG), fatG: v(.fatG),
                  fiberG: v(.fiberG), sugarG: v(.sugarG), saltG: v(.saltG),
                  caffeineMg: v(.caffeineMg), alcoholG: v(.alcoholG))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kcal, forKey: .kcal); try c.encode(proteinG, forKey: .proteinG)
        try c.encode(carbsG, forKey: .carbsG); try c.encode(fatG, forKey: .fatG)
        try c.encode(fiberG, forKey: .fiberG); try c.encode(sugarG, forKey: .sugarG)
        try c.encode(saltG, forKey: .saltG); try c.encode(caffeineMg, forKey: .caffeineMg)
        try c.encode(alcoholG, forKey: .alcoholG)
    }
}
