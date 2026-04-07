// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VoiceInk",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "voiceink", targets: ["VoiceInk"]),
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
        .target(
            name: "VoiceInkLib",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("Carbon"),
            ]
        ),
    ]
)
