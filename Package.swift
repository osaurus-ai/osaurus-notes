// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "osaurus-notes",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "osaurus-notes", type: .dynamic, targets: ["osaurus_notes"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/osaurus-ai/osaurus-plugin-sdk.git",
            revision: "21b4e133b365ff73c25d4a9db60d207c1888a6ab"
        )
    ],
    targets: [
        .target(
            name: "osaurus_notes",
            dependencies: [
                .product(name: "OsaurusPluginABI", package: "osaurus-plugin-sdk"),
                .product(name: "OsaurusPluginKit", package: "osaurus-plugin-sdk"),
            ],
            path: "Sources/osaurus_notes"
        ),
        .testTarget(
            name: "osaurus_notesTests",
            dependencies: [
                "osaurus_notes",
                .product(name: "OsaurusPluginTestSupport", package: "osaurus-plugin-sdk"),
            ],
            path: "Tests/osaurus_notesTests"
        )
    ]
)
