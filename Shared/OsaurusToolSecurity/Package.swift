// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OsaurusToolSecurity",
    platforms: [.macOS(.v13)],
    products: [
        .library(
            name: "OsaurusToolSecurity",
            type: .static,
            targets: ["OsaurusToolSecurity"]
        )
    ],
    targets: [
        .target(
            name: "OsaurusToolSecurity",
            path: "Sources/OsaurusToolSecurity"
        ),
        .testTarget(
            name: "OsaurusToolSecurityTests",
            dependencies: ["OsaurusToolSecurity"],
            path: "Tests/OsaurusToolSecurityTests"
        ),
    ]
)
