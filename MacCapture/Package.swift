// swift-tools-version: 6.0
import PackageDescription

// DumpNotes Capture: a menu-bar panel for throwing notes, photos and videos into the journal
// from a Mac. It writes captures into a folder in iCloud Drive; the phone files them.
// Built into an .app by build-app.sh (`make mac-capture` from the repo root).
let package = Package(
    name: "DumpNotesCapture",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../Core")],
    targets: [
        .executableTarget(
            name: "DumpNotesCapture",
            dependencies: [.product(name: "CodenamePromiseCore", package: "Core")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
