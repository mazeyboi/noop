import Foundation

/// The bundled generic-foods list (USDA FoodData Central SR Legacy, public domain), searched offline.
public final class GenericFoods: @unchecked Sendable {
    public static let shared = GenericFoods()
    public static let attribution = "Generic foods: U.S. Department of Agriculture, Agricultural Research Service. "
        + "FoodData Central (SR Legacy, 2018), fdc.nal.usda.gov. Public domain."

    private struct Row: Decodable {
        var n: String
        var k, p, c, f, fi, s, sa, ca, al, sg: Double?
        var sn: String?
    }

    private struct Indexed { let food: Food; let words: [Substring]; let wordCount: Int }

    private lazy var items: [Indexed] = load()
    private let lock = NSLock()

    public var count: Int { lock.withLock { items.count } }

    private func load() -> [Indexed] {
        guard let url = Bundle.module.url(forResource: "generic_foods", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let rows = try? JSONDecoder().decode([Row].self, from: data) else { return [] }
        return rows.enumerated().map { i, r in
            let food = Food(id: "usda-\(Self.stableId(r.n))", name: r.n, source: .generic,
                            per100: Nutrients(kcal: r.k ?? 0, proteinG: r.p ?? 0, carbsG: r.c ?? 0, fatG: r.f ?? 0,
                                              fiberG: r.fi ?? 0, sugarG: r.s ?? 0, saltG: r.sa ?? 0,
                                              caffeineMg: r.ca ?? 0, alcoholG: r.al ?? 0),
                            servingG: r.sg, servingName: r.sn, updatedAt: Date(timeIntervalSince1970: 0))
            let words = Self.words(r.n)
            return Indexed(food: food, words: words, wordCount: words.count)
        }
    }

    static func words(_ s: String) -> [Substring] {
        s.lowercased().split { !$0.isLetter && !$0.isNumber }
    }

    /// FNV-1a over UTF-8: the same food always gets the same id, on every install.
    static func stableId(_ s: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return String(h, radix: 16)
    }

    /// Every query word must start one of the food's words. Fewer, shorter names rank first.
    public func search(_ query: String, limit: Int = 30) -> [Food] {
        let q = Self.words(query)
        guard !q.isEmpty else { return [] }
        return lock.withLock {
            items.filter { item in q.allSatisfy { qw in item.words.contains { $0.hasPrefix(qw) } } }
                .sorted { a, b in
                    let aFirst = a.words.first.map { $0.hasPrefix(q[0]) } ?? false
                    let bFirst = b.words.first.map { $0.hasPrefix(q[0]) } ?? false
                    if aFirst != bFirst { return aFirst }
                    if a.wordCount != b.wordCount { return a.wordCount < b.wordCount }
                    return a.food.name.count < b.food.name.count
                }
                .prefix(limit).map(\.food)
        }
    }
}
