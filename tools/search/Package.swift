// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OsaurusSearch",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "OsaurusSearch", type: .dynamic, targets: ["OsaurusSearch"])
    ],
    targets: [
        .target(
            name: "OsaurusSearch",
            path: "Sources/OsaurusSearch"
        ),
        .testTarget(
            name: "OsaurusSearchTests",
            dependencies: ["OsaurusSearch"],
            path: "Tests/OsaurusSearchTests"
        ),
    ]
)
