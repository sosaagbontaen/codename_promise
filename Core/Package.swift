// swift-tools-version: 6.0
import PackageDescription

// The domain + persistence core lives in a package so it builds and tests from the
// command line without an Xcode app target. The SwiftUI app target depends on this.
// Rationale: ADR-025 — the "never lose work" guarantees need fast, headless tests.
let package = Package(
    name: "CodenamePromiseCore",
    platforms: [
        .iOS(.v17),     // SwiftData + @Observable
        .macOS(.v14),   // so `swift test` can run the same code headlessly
    ],
    products: [
        .library(name: "CodenamePromiseCore", targets: ["CodenamePromiseCore"])
    ],
    targets: [
        .target(
            name: "CodenamePromiseCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CodenamePromiseCoreTests",
            dependencies: ["CodenamePromiseCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
