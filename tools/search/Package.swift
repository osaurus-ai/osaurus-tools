// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OsaurusSearch",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "OsaurusSearch", type: .dynamic, targets: ["OsaurusSearch"])
    ],
    dependencies: [
        .package(path: "../../Shared/OsaurusToolSecurity")
    ],
    targets: [
        .target(
            name: "OsaurusSearch",
            dependencies: ["OsaurusToolSecurity"],
            path: "Sources/OsaurusSearch"
        ),
        .testTarget(
            name: "OsaurusSearchTests",
            dependencies: ["OsaurusSearch"],
            path: "Tests/OsaurusSearchTests"
        ),
    ]
)
