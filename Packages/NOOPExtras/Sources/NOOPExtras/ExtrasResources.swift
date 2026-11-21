import Foundation

public enum ExtrasResources {
    /// A drawn plate (rice, chicken, broccoli) for the AI provider "Test" button. PNG; the UI converts
    /// it to JPEG before sending.
    public static func samplePNG() -> Data? {
        Bundle.module.url(forResource: "sample_meal", withExtension: "png").flatMap { try? Data(contentsOf: $0) }
    }

    public static let openFoodFactsAttribution =
        "Product data from Open Food Facts (openfoodfacts.org), available under the Open Database License."
}
