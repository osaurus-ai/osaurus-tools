// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OsaurusFetch",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "OsaurusFetch", type: .dynamic, targets: ["OsaurusFetch"])
    ],
    targets: [
        .target(
            name: "OsaurusFetch",
            path: "Sources/OsaurusFetch"
        ),
        .testTarget(
            name: "OsaurusFetchTests",
            dependencies: ["OsaurusFetch"],
            path: "Tests/OsaurusFetchTests"
        ),
    ]
)
