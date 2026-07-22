// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RepoDocs",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(name: "CharmingEditor", path: "../strudel-markdown-editor"),
        .package(url: "https://github.com/tree-sitter/swift-tree-sitter", from: "0.8.0"),
        .package(url: "https://github.com/tree-sitter-grammars/tree-sitter-markdown", from: "0.5.3"),
    ],
    targets: [
        .executableTarget(
            name: "RepoDocs",
            dependencies: [
                .product(name: "CharmingEditor", package: "CharmingEditor"),
                .product(name: "SwiftTreeSitter", package: "swift-tree-sitter"),
                .product(name: "TreeSitterMarkdown", package: "tree-sitter-markdown"),
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
