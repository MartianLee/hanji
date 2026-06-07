// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "hanji",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "hanji", targets: ["HanjiApp"])
    ],
    targets: [
        .target(name: "MarkdownCore"),
        .target(name: "VaultKit", dependencies: ["MarkdownCore"]),
        .target(name: "ExtensionSDK"),
        .target(name: "AppCore", dependencies: ["VaultKit", "ExtensionSDK"]),
        .target(name: "WordCountPlugin", dependencies: ["ExtensionSDK"]),
        .target(name: "CoreRenderers", dependencies: ["ExtensionSDK"]),
        .target(name: "EditorEngine", dependencies: ["MarkdownCore", "ExtensionSDK"]),
        .executableTarget(name: "HanjiApp", dependencies: [
            "AppCore", "EditorEngine", "ExtensionSDK", "WordCountPlugin", "CoreRenderers", "VaultKit"
        ]),
        .executableTarget(name: "Checks", dependencies: ["MarkdownCore", "VaultKit", "AppCore", "ExtensionSDK", "WordCountPlugin", "EditorEngine"]),
    ]
)
