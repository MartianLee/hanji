// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "hanji",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "hanji", targets: ["HanjiApp"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0")
    ],
    targets: [
        .target(name: "MarkdownCore"),
        .target(name: "VaultKit", dependencies: ["MarkdownCore"]),
        .target(name: "ExtensionSDK"),
        .target(name: "MKSearchKit", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),
        .target(name: "AppCore", dependencies: ["VaultKit", "ExtensionSDK", "MKSearchKit"]),
        .target(name: "WordCountPlugin", dependencies: ["ExtensionSDK"]),
        .target(name: "CoreRenderers", dependencies: ["ExtensionSDK", "VaultKit", "MarkdownCore"]),
        .target(name: "EditorEngine", dependencies: ["MarkdownCore", "ExtensionSDK"]),
        .target(name: "TemplateKit"),
        .target(name: "PeriodicNotesPlugin", dependencies: ["ExtensionSDK", "TemplateKit"]),
        .target(name: "TemplaterPlugin", dependencies: ["ExtensionSDK", "TemplateKit"]),
        .executableTarget(name: "HanjiApp", dependencies: [
            "AppCore", "EditorEngine", "ExtensionSDK", "WordCountPlugin", "CoreRenderers",
            "VaultKit", "MarkdownCore", "TemplateKit", "PeriodicNotesPlugin", "TemplaterPlugin"
        ]),
        .executableTarget(name: "Checks", dependencies: ["MarkdownCore", "VaultKit", "AppCore", "ExtensionSDK", "WordCountPlugin", "EditorEngine", "TemplateKit", "PeriodicNotesPlugin", "MKSearchKit"]),
    ]
)
