// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "hanji",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "hanji", targets: ["HanjiApp"]),
        // The extension SDK + pure libraries, exported so plugin/tooling authors
        // can build against them. (First-party plugins are compile-time — see
        // CONTRIBUTING.md — but exposing these makes the SDK a real dependency.)
        .library(name: "ExtensionSDK", targets: ["ExtensionSDK"]),
        .library(name: "MarkdownCore", targets: ["MarkdownCore"]),
        .library(name: "TemplateKit", targets: ["TemplateKit"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0")
    ],
    targets: [
        .target(name: "MarkdownCore"),
        .target(name: "VaultKit", dependencies: ["MarkdownCore"]),
        .target(name: "ExtensionSDK"),
        .target(name: "MKSearchKit", dependencies: ["MarkdownCore", .product(name: "GRDB", package: "GRDB.swift")]),
        .target(name: "AppCore", dependencies: ["VaultKit", "ExtensionSDK", "MKSearchKit", "MarkdownCore"]),
        .target(name: "WordCountPlugin", dependencies: ["ExtensionSDK"]),
        .target(name: "CoreRenderers", dependencies: ["ExtensionSDK", "VaultKit", "MarkdownCore"]),
        .target(name: "EditorEngine", dependencies: ["MarkdownCore", "ExtensionSDK"]),
        .target(name: "TemplateKit"),
        .target(name: "PeriodicNotesPlugin", dependencies: ["ExtensionSDK", "TemplateKit"]),
        .target(name: "TemplaterPlugin", dependencies: ["ExtensionSDK", "TemplateKit"]),
        .target(name: "BacklinksPlugin", dependencies: ["ExtensionSDK"]),
        .target(name: "CalendarPlugin", dependencies: ["ExtensionSDK"]),
        .executableTarget(name: "HanjiApp", dependencies: [
            "AppCore", "EditorEngine", "ExtensionSDK", "WordCountPlugin", "CoreRenderers",
            "VaultKit", "MarkdownCore", "TemplateKit", "PeriodicNotesPlugin", "TemplaterPlugin",
            "MKSearchKit", "BacklinksPlugin", "CalendarPlugin"
        ]),
        .executableTarget(name: "Checks", dependencies: ["MarkdownCore", "VaultKit", "AppCore", "ExtensionSDK", "WordCountPlugin", "EditorEngine", "TemplateKit", "PeriodicNotesPlugin", "MKSearchKit", "BacklinksPlugin", "CalendarPlugin", "CoreRenderers"]),
    ]
)
