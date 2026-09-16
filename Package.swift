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
        .package(url: "https://github.com/octavore/crumpet", from: "0.1.0"),
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
                .product(name: "Crumpet", package: "crumpet"),
            ],
            path: "Sources/RepoDocs",
            linkerSettings: [
                .unsafeFlags(["-L\(packageDir)/target/uniffi", "-lrd_core"])
            ]
        ),
    ]
)
