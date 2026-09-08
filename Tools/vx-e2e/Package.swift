// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "vx-e2e",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "vx-e2e", targets: ["vx-e2e"])
    ],
    targets: [
        .executableTarget(
            name: "vx-e2e",
            path: "Sources/vx-e2e",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ImageIO")
            ]
        ),
        .testTarget(
            name: "vx-e2eTests",
            dependencies: ["vx-e2e"],
            path: "Tests/vx-e2eTests"
        )
    ]
)
