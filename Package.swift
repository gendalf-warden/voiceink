// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VoiceInk",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "voiceink", targets: ["VoiceInk"]),
        .executable(name: "UIPreview", targets: ["UIPreview"]),
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
