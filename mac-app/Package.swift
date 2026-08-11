// swift-tools-version: 5.9
import PackageDescription
import Foundation

// Sparkle is opt-in at build time.
//
// The default `swift build` has no package dependencies at all: it works
// offline, on a fresh checkout, behind a corporate proxy, and on a machine that
// has never talked to GitHub. That property is worth keeping for a tool whose
// whole job is to sit quietly in the corner of a desktop.
//
// Release builds want auto-update, so `scripts/build-app.sh` sets
// CLAUDE_STATUS_SPARKLE=1 and the framework comes in. The code behind it is
// guarded with `#if canImport(Sparkle)`, so both shapes compile.
let wantsSparkle = ProcessInfo.processInfo.environment["CLAUDE_STATUS_SPARKLE"] == "1"

let package = Package(
    name: "StatusPet",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "StatusPet", targets: ["StatusPet"]),
        .library(name: "StatusPetCore", targets: ["StatusPetCore"])
    ],
    dependencies: wantsSparkle
        ? [.package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")]
        : [],
    targets: [
        // Everything with behaviour worth testing lives here. The executable is
        // a single line, so nothing important is stranded outside the reach of
        // the test target.
        .target(
            name: "StatusPetCore",
            dependencies: wantsSparkle ? [.product(name: "Sparkle", package: "Sparkle")] : [],
            path: "Sources/StatusPetCore"
        ),
        .executableTarget(
            name: "StatusPet",
            dependencies: ["StatusPetCore"],
            path: "Sources/StatusPet"
        ),
        .testTarget(
            name: "StatusPetCoreTests",
            dependencies: ["StatusPetCore"],
            path: "Tests/StatusPetCoreTests"
        )
    ]
)
