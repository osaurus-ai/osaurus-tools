// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OsaurusFetch",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "OsaurusFetch", type: .dynamic, targets: ["OsaurusFetch"])
    ],
    dependencies: [
        .package(path: "../../Shared/OsaurusToolSecurity")
    ],
    targets: [
        .target(
            name: "OsaurusFetch",
            dependencies: ["OsaurusToolSecurity"],
            path: "Sources/OsaurusFetch"
        ),
        .testTarget(
            name: "OsaurusFetchTests",
            dependencies: ["OsaurusFetch"],
            path: "Tests/OsaurusFetchTests"
        ),
    ]
)
