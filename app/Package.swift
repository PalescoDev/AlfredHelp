// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AlfredHelp",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "AlfredHelpCore", targets: ["AlfredHelpCore"]),
        .executable(name: "AlfredHelp", targets: ["AlfredHelpApp"])
    ],
    targets: [
        .target(
            name: "AlfredHelpCore",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .executableTarget(
            name: "AlfredHelpApp",
            dependencies: ["AlfredHelpCore"],
            swiftSettings: [
                // The UI layer is overwhelmingly @MainActor AppKit/SwiftUI code.
                // Language mode 5 keeps that ergonomic; the concurrency-heavy
                // audio/LLM code lives in AlfredHelpCore under mode 6.
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "AlfredHelpCoreTests",
            dependencies: ["AlfredHelpCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
