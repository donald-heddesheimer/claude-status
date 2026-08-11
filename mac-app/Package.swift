// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "StatusPet",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "StatusPet",
            path: "Sources/StatusPet"
        )
    ]
)
