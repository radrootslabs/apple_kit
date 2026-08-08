// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RadrootsKit",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(
            name: "RadrootsKit",
            targets: ["RadrootsKit"]
        ),
        .library(
            name: "RadrootsKitTesting",
            targets: ["RadrootsKitTesting"]
        ),
    ],
    dependencies: [
        .package(
            url: "https://github.com/21-DOT-DEV/swift-secp256k1.git",
            revision: "e70a10e036a55fffea31568f0af92d69b6d449cd"
        ),
    ],
    targets: [
        .target(
            name: "RadrootsKit",
            dependencies: [
                .product(name: "P256K", package: "swift-secp256k1"),
            ],
            resources: [
                .process("PrivacyInfo.xcprivacy"),
            ],
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedFramework("LocalAuthentication"),
                .linkedFramework("UserNotifications"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Photos"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ImageIO"),
                .linkedFramework("UniformTypeIdentifiers"),
                .linkedFramework("CoreLocation"),
                .linkedFramework("BackgroundTasks", .when(platforms: [.iOS])),
            ]
        ),
        .target(
            name: "RadrootsKitTesting",
            dependencies: ["RadrootsKit"]
        ),
        .testTarget(
            name: "RadrootsKitTests",
            dependencies: ["RadrootsKit", "RadrootsKitTesting"]
        ),
        .testTarget(
            name: "RadrootsKitTestingTests",
            dependencies: ["RadrootsKitTesting"]
        ),
    ]
)
