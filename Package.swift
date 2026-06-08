// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AmigaDiskKit",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "AmigaDiskKit", targets: ["AmigaDiskKit"]),
        .executable(name: "AmigaDiskCLI", targets: ["AmigaDiskCLI"]),
    ],
    targets: [
        .target(
            name: "AmigaDiskKit",
            path: "Sources/AmigaDiskKit"
        ),
        .executableTarget(
            name: "AmigaDiskCLI",
            dependencies: ["AmigaDiskKit"],
            path: "Sources/AmigaDiskCLI"
        ),
        .testTarget(
            name: "AmigaDiskKitTests",
            dependencies: ["AmigaDiskKit"],
            path: "Tests/AmigaDiskKitTests",
            resources: [
                .copy("Fixtures"),
            ]
        ),
    ]
)
