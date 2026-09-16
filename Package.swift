// swift-tools-version: 6.0
import Foundation
import PackageDescription

// Resolved from the manifest's own location rather than the working directory,
// so the linker finds the Rust staticlib no matter where `swift build` is
// invoked from (strudel runs it from its own cwd).
let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

let package = Package(
    name: "RepoDocs",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(name: "CharmingEditor", path: "../strudel-markdown-editor"),
        .package(url: "https://github.com/tree-sitter/swift-tree-sitter", from: "0.8.0"),
        .package(
            url: "https://github.com/tree-sitter-grammars/tree-sitter-markdown", from: "0.5.3"),
    ],
    targets: [
        // The generated C header and modulemap for the Rust core. Both, and the
        // Swift bindings in RepoDocsCore, are produced by
        // `scripts/build-core.sh` (`axo core`) and are not checked in.
        .target(name: "rd_coreFFI"),
        .target(name: "RepoDocsCore", dependencies: ["rd_coreFFI"]),
        .executableTarget(
            name: "RepoDocs",
            dependencies: [
                "RepoDocsCore",
                .product(name: "CharmingEditor", package: "CharmingEditor"),
                .product(name: "SwiftTreeSitter", package: "swift-tree-sitter"),
                .product(name: "TreeSitterMarkdown", package: "tree-sitter-markdown"),
            ],
            path: "Sources/RepoDocs",
            linkerSettings: [
                .unsafeFlags(["-L\(packageDir)/target/uniffi", "-lrd_core"])
            ]
        ),
    ]
)
