// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "osaurus-notes",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "osaurus-notes", type: .dynamic, targets: ["osaurus_notes"])
    ],
    targets: [
        .target(
            name: "osaurus_notes",
            path: "Sources/osaurus_notes"
        ),
        .testTarget(
            name: "osaurus_notesTests",
            dependencies: ["osaurus_notes"],
            path: "Tests/osaurus_notesTests"
        )
    ]
)