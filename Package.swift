// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "osaurus-notes",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "osaurus-notes", type: .dynamic, targets: ["osaurus_notes"])
    ],
    dependencies: [
        .package(url: "https://github.com/osaurus-ai/osaurus-plugin-sdk.git", exact: "1.0.0")
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
