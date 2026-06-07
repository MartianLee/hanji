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
        .executableTarget(name: "HanjiApp"),
        .executableTarget(name: "Checks", dependencies: ["MarkdownCore"]),
    ]
)
