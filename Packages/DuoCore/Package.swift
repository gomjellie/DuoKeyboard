// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "DuoCore",
    defaultLocalization: "ko",
    platforms: [.macOS(.v26)],
    products: [
        // Pure, platform-independent engine: 두벌식 automaton, language model, composition state machine.
        .library(name: "DuoCore", targets: ["DuoCore"]),
    ],
    targets: [
        .target(
            name: "DuoCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "DuoCoreTests",
            dependencies: ["DuoCore"],
            resources: [.copy("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
