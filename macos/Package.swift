// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Sist",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SistCore", targets: ["SistCore"]),
        .library(name: "SistStore", targets: ["SistStore"]),
        .library(name: "SistExtractors", targets: ["SistExtractors"]),
        .library(name: "SistScan", targets: ["SistScan"]),
        .executable(name: "sist", targets: ["sist"]),
        .executable(name: "sist-worker", targets: ["sist-worker"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        // Models, MIME detection, CJK-aware search text, query parsing, highlighting, directory walk,
        // ignore rules and the worker wire format. No dependencies, builds everywhere.
        .target(name: "SistCore"),

        // The catalog: one SQLite database (GRDB) holding sources, documents, content, thumbnails,
        // tags and the FTS5 index. The scan writer and the search/stats queries live here.
        .target(
            name: "SistStore",
            dependencies: [
                "SistCore",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),

        // Per-format extractors. Portable ones (text, markup, json, OOXML, EPUB, zip) build
        // everywhere; PDFKit / ImageIO / Vision / AVFoundation / CoreText / QuickLook ones only on macOS.
        .target(
            name: "SistExtractors",
            dependencies: [
                "SistCore",
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ]
        ),

        // Scan pipeline: walk -> mark unchanged -> parser pool (in-process or sist-worker
        // processes) -> single catalog writer.
        .target(
            name: "SistScan",
            dependencies: ["SistCore", "SistStore", "SistExtractors"]
        ),

        .executableTarget(
            name: "sist-worker",
            dependencies: ["SistCore", "SistExtractors"]
        ),

        .executableTarget(
            name: "sist",
            dependencies: [
                "SistScan",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),

        .testTarget(
            name: "SistCoreTests",
            dependencies: ["SistCore"]
        ),
        .testTarget(
            name: "SistStoreTests",
            dependencies: ["SistStore"]
        ),
        .testTarget(
            name: "SistExtractorsTests",
            dependencies: [
                "SistExtractors",
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ]
        ),
        .testTarget(
            name: "SistScanTests",
            // Depending on the executable makes `swift test` build it, so the subprocess pool can be tested
            dependencies: [
                "SistScan",
                "sist-worker",
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ]
        ),
    ]
)

// The SwiftUI app only exists on macOS. Keeping it out of the manifest elsewhere lets the engine
// build and test on Linux CI.
#if os(macOS)
package.products.append(.executable(name: "SistApp", targets: ["SistApp"]))
package.targets.append(
    .executableTarget(
        name: "SistApp",
        dependencies: ["SistCore", "SistStore", "SistScan"],
        path: "App/Sources",
        swiftSettings: [.swiftLanguageMode(.v5)]
    )
)
#endif
