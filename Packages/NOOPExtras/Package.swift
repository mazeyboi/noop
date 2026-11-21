// swift-tools-version: 5.9
// NOOPExtras — the fork's food log, sync engine and NOOP data reader (mazeyboi/noop only).
// Lives outside every upstream package and owns its own SQLite file, so upstream merges never touch it.
import PackageDescription

let package = Package(
    name: "NOOPExtras",
    defaultLocalization: "en",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [
        .library(name: "NOOPExtras", targets: ["NOOPExtras"]),
        .library(name: "NOOPExtrasUI", targets: ["NOOPExtrasUI"]),
    ],
    dependencies: [
        // Same exact pin as every upstream package (SPM refuses two different exact versions).
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "6.29.3"),
        .package(path: "../StrandDesign"),
        // Tests only: builds the fixture database with upstream's CURRENT migrator, so an upstream
        // schema change breaks NOOPDataReaderTests in CI instead of breaking sync on the phone.
        .package(path: "../WhoopStore"),
    ],
    targets: [
        .target(
            name: "NOOPExtras",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
            resources: [.process("Resources")]
        ),
        .target(
            name: "NOOPExtrasUI",
            dependencies: ["NOOPExtras", .product(name: "StrandDesign", package: "StrandDesign")]
        ),
        .testTarget(
            name: "NOOPExtrasTests",
            dependencies: [
                "NOOPExtras",
                .product(name: "WhoopStore", package: "WhoopStore"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            resources: [.copy("Fixtures")]
        ),
    ]
)
