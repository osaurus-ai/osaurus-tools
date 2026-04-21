// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OsaurusTime",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "OsaurusTime", type: .dynamic, targets: ["OsaurusTime"])
    ],
    targets: [
        .target(
            name: "OsaurusTime",
            path: "Sources/OsaurusTime"
        ),
        .testTarget(
            name: "OsaurusTimeTests",
            dependencies: ["OsaurusTime"],
            path: "Tests/OsaurusTimeTests"
        ),
    ]
)
