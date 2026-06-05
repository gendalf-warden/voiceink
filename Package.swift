// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VoiceInk",
    defaultLocalization: "en",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "voiceink", targets: ["VoiceInk"]),
        .executable(name: "UIPreview", targets: ["UIPreview"]),
    ],
    dependencies: [
        // Sparkle 2.x — auto-updater. Only linked into VoiceInkLib. Used by
        // UpdateController to expose «Check for Updates…» menu action. See
        // Phase 7 in PROJECT.md and CLAUDE.md → Auto-update.
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "VoiceInk",
            dependencies: ["VoiceInkLib"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudio"),
            ]
        ),
        .executableTarget(
            name: "UIPreview",
            dependencies: ["VoiceInkLib"],
            linkerSettings: [
                .linkedFramework("AppKit"),
            ]
        ),
        .target(
            name: "VoiceInkLib",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            resources: [
                .process("Resources"),
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("Carbon"),
            ]
        ),
        .testTarget(
            name: "VoiceInkTests",
            dependencies: ["VoiceInkLib"]
        ),
    ]
)
