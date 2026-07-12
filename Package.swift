// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RepoDocs",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(name: "CharmingEditor", path: "../strudel-markdown-editor")
    ],
    targets: [
        .executableTarget(
            name: "RepoDocs",
            dependencies: [
                .product(name: "CharmingEditor", package: "CharmingEditor")
            ],
            path: "Sources/RepoDocs"
        ),
        .testTarget(
            name: "RepoDocsTests",
            dependencies: ["RepoDocs"],
            path: "Tests/RepoDocsTests"
        ),
    ]
)
