// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AmigaDiskKit",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        // Explicitly static: amiga-tools is copied standalone into the app's
        // Resources and exec'd by the build scripts — a dynamic PackageProduct
        // framework cannot be loaded from there (rpath + Team-ID signing
        // mismatch → dyld abort). Static linking restores self-contained
        // binaries for every client (app, amiga-tools, tests).
        .library(name: "AmigaDiskKit", type: .static, targets: ["AmigaDiskKit"]),
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
