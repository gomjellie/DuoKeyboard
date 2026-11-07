// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "DuoCore",
    defaultLocalization: "ko",
    platforms: [.macOS(.v26)],
    products: [
        // Pure, platform-independent engine: 두벌식 automaton, language model, composition state machine.
        .library(name: "DuoCore", targets: ["DuoCore"]),
        // macOS integration shared by the input method and the host app: TIS install/select, settings, IPC.
        .library(name: "DuoKit", targets: ["DuoKit"]),
    ],
    targets: [
        .target(
            name: "DuoCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "DuoKit",
            dependencies: ["DuoCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "DuoCoreTests",
            dependencies: ["DuoCore", "DuoKit"],
            resources: [.copy("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
