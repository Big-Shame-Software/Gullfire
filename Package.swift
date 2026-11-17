// swift-tools-version: 6.2
import PackageDescription

/// Gullfire. GullfireKit holds all the logic and has no UI or network code.
/// gullfire-pack turns a prepared city (Cities/<city>/raw) into a city package.
let package = Package(
    name: "Gullfire",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "GullfireKit", targets: ["GullfireKit"]),
        .executable(name: "gullfire-pack", targets: ["gullfire-pack"]),
        .executable(name: "gullfire-render", targets: ["gullfire-render"]),
    ],
    dependencies: [
        // The vendored Gadgets package (Packages/Gadgets, from scripts/update-gadgets.sh): the MIDI pad and loop.
        .package(path: "Packages/Gadgets"),
    ],
    targets: [
        .target(name: "GullfireKit",
                dependencies: [
                    .product(name: "BSSMidiLoop", package: "Gadgets"),
                    .product(name: "BSSMidiPlayer", package: "Gadgets"),
                ],
                swiftSettings: [.swiftLanguageMode(.v6)]),
        .executableTarget(name: "gullfire-pack", dependencies: ["GullfireKit"], swiftSettings: [.swiftLanguageMode(.v6)]),
        .executableTarget(name: "gullfire-render", dependencies: ["GullfireKit"], swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "GullfireKitTests", dependencies: ["GullfireKit"], swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)
