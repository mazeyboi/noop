// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NutritionCore",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "NutritionCore", targets: ["NutritionCore"])],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "6.29.3"),
    ],
    targets: [
        .target(
            name: "NutritionCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        .testTarget(
            name: "NutritionCoreTests",
            dependencies: ["NutritionCore"]
        ),
    ]
)
