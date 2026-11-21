import Foundation
import GRDB

/// Open Food Facts lookups, straight from the phone (no account, no key). Barcode results are cached
/// locally for 30 days, including "not found".
public struct OpenFoodFacts: Sendable {
    let transport: HTTPTransport
    let store: ExtrasStore
    let now: @Sendable () -> Date
    static let base = "https://world.openfoodfacts.org"
    static let fields = "code,product_name,brands,nutriments,serving_quantity,serving_size"
    static let userAgent = "NOOPExtras/1.0 (personal fork of NOOP)"
    static let cacheSeconds: TimeInterval = 30 * 86400

    public init(transport: HTTPTransport, store: ExtrasStore, now: @escaping @Sendable () -> Date = { Date() }) {
        self.transport = transport; self.store = store; self.now = now
    }

    private func get(_ url: URL) async throws -> [String: Any] {
        var r = URLRequest(url: url, timeoutInterval: 15)
        r.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await transport.send(r)
        guard (200..<300).contains(resp.statusCode) || resp.statusCode == 404 else {
            throw URLError(.badServerResponse)
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// nil = Open Food Facts doesn't know this barcode.
    public func product(barcode raw: String) async throws -> Food? {
        let code = raw.trimmingCharacters(in: .whitespaces)
        guard !code.isEmpty, code.count <= 32, code.allSatisfy(\.isASCII), code.allSatisfy(\.isNumber) else { return nil }
        if let cached = try cachedProduct(code) { return cached.food }
        let url = URL(string: "\(Self.base)/api/v2/product/\(code).json?fields=\(Self.fields)")!
        let obj = try await get(url)
        let food: Food?
        if (obj["status"] as? NSNumber)?.intValue == 1, let p = obj["product"] as? [String: Any] {
            food = Self.food(from: p, barcode: code)
        } else {
            food = nil
        }
        try cache(code, food)
        return food
    }

    public func search(_ query: String) async throws -> [Food] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else { return [] }
        var c = URLComponents(string: "\(Self.base)/cgi/search.pl")!
        c.queryItems = [URLQueryItem(name: "search_terms", value: q), URLQueryItem(name: "json", value: "1"),
                        URLQueryItem(name: "page_size", value: "20"), URLQueryItem(name: "fields", value: Self.fields),
                        URLQueryItem(name: "search_simple", value: "1")]
        let obj = try await get(c.url!)
        return (obj["products"] as? [[String: Any]] ?? []).compactMap {
            Self.food(from: $0, barcode: ($0["code"] as? String) ?? "")
        }
    }

    static func number(_ d: [String: Any], _ k: String) -> Double? {
        if let n = d[k] as? NSNumber { return n.doubleValue }
        if let s = d[k] as? String { return Double(s.replacingOccurrences(of: ",", with: ".")) }
        return nil
    }

    static func food(from p: [String: Any], barcode: String) -> Food? {
        guard let name = (p["product_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty
        else { return nil }
        let n = p["nutriments"] as? [String: Any] ?? [:]
        let kcal = number(n, "energy-kcal_100g") ?? number(n, "energy_100g").map { $0 / 4.184 } ?? 0
        let per100 = Nutrients(
            kcal: kcal,
            proteinG: number(n, "proteins_100g") ?? 0,
            carbsG: number(n, "carbohydrates_100g") ?? 0,
            fatG: number(n, "fat_100g") ?? 0,
            fiberG: number(n, "fiber_100g") ?? 0,
            sugarG: number(n, "sugars_100g") ?? 0,
            saltG: number(n, "salt_100g") ?? 0,
            caffeineMg: (number(n, "caffeine_100g") ?? 0) * 1000,   // OFF stores grams
            alcoholG: (number(n, "alcohol_100g") ?? 0) * 0.789)     // OFF stores % vol
        let brand = (p["brands"] as? String)?.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) }
        let serving = number(p, "serving_quantity").flatMap { $0 > 0 ? $0 : nil }
        return Food(id: "off-\(barcode.isEmpty ? UUID().uuidString : barcode)", name: name,
                    brand: brand?.isEmpty == false ? brand : nil, barcode: barcode.isEmpty ? nil : barcode,
                    source: .off, per100: per100, servingG: serving,
                    servingName: (p["serving_size"] as? String).flatMap { $0.isEmpty ? nil : $0 })
    }

    // MARK: cache

    private struct Cached { var food: Food? }

    private func cachedProduct(_ code: String) throws -> Cached? {
        let row = try store.db.read { db in
            try Row.fetchOne(db, sql: "SELECT json, fetchedAt FROM offCache WHERE barcode = ?", arguments: [code])
        }
        guard let row else { return nil }
        let fetchedAt: Double = row["fetchedAt"]
        guard now().timeIntervalSince1970 - fetchedAt < Self.cacheSeconds else { return nil }
        let json: String? = row["json"]
        return Cached(food: try json.map { try ExtrasCodec.dbDecoder.decode(Food.self, from: Data($0.utf8)) })
    }

    private func cache(_ code: String, _ food: Food?) throws {
        let json = try food.map { String(decoding: try ExtrasCodec.dbEncoder.encode($0), as: UTF8.self) }
        try store.db.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO offCache (barcode, json, fetchedAt) VALUES (?, ?, ?)",
                           arguments: [code, json, now().timeIntervalSince1970])
        }
    }
}
