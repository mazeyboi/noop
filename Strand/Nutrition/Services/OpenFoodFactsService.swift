import Foundation
import NutritionCore

enum BarcodeLookupError: LocalizedError {
    case invalidBarcode
    case productNotFound
    case malformedNutrition
    case network
    case server

    var errorDescription: String? {
        switch self {
        case .invalidBarcode: return "This barcode is not a supported packaged-food code."
        case .productNotFound: return "Open Food Facts has no product for this barcode."
        case .malformedNutrition: return "The product was found, but its nutrition data is incomplete."
        case .network: return "The product could not be looked up. Check your connection and try again."
        case .server: return "Open Food Facts is unavailable right now."
        }
    }
}

struct OpenFoodFactsService {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func find(barcode: String) async throws -> NutritionFood {
        let code = barcode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (8...14).contains(code.count), code.allSatisfy(\.isNumber) else {
            throw BarcodeLookupError.invalidBarcode
        }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "world.openfoodfacts.org"
        components.path = "/api/v2/product/\(code)"
        components.queryItems = [
            URLQueryItem(
                name: "fields",
                value: "product_name,brands,serving_size,serving_quantity,serving_quantity_unit,nutriments"
            )
        ]
        guard let url = components.url else { throw BarcodeLookupError.invalidBarcode }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        request.setValue("NOOP/\(version) (https://github.com/ryanbr/noop)", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw BarcodeLookupError.network
        }
        guard let http = response as? HTTPURLResponse else { throw BarcodeLookupError.network }
        if http.statusCode == 404 { throw BarcodeLookupError.productNotFound }
        guard (200..<300).contains(http.statusCode) else { throw BarcodeLookupError.server }
        do {
            return try OpenFoodFactsNormalizer.food(from: data, barcode: code)
        } catch OpenFoodFactsError.productNotFound {
            throw BarcodeLookupError.productNotFound
        } catch OpenFoodFactsError.malformedNutrition {
            throw BarcodeLookupError.malformedNutrition
        } catch {
            throw BarcodeLookupError.server
        }
    }
}
