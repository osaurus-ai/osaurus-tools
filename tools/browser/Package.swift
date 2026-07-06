// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OsaurusBrowser",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "OsaurusBrowser", type: .dynamic, targets: ["OsaurusBrowser"])
    ],
    dependencies: [
        .package(path: "../../Shared/OsaurusToolSecurity")
    ],
    targets: [
        .target(
            name: "OsaurusBrowser",
            dependencies: ["OsaurusToolSecurity"],
            path: "Sources/OsaurusBrowser",
            linkerSettings: [
                .linkedFramework("WebKit"),
                .linkedFramework("AppKit"),
            ]
        ),
        .testTarget(
            name: "OsaurusBrowserTests",
            dependencies: ["OsaurusBrowser", "OsaurusToolSecurity"],
            path: "Tests/OsaurusBrowserTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
