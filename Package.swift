// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RadrootsKit",
    platforms: [
        .iOS(.v18),
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "RadrootsKit",
            targets: ["RadrootsKit"]
        ),
        .library(
            name: "RadrootsKitTesting",
            targets: ["RadrootsKitTesting"]
        )
    ],
    targets: [
        .target(
            name: "RadrootsKit",
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedFramework("LocalAuthentication"),
                .linkedFramework("UserNotifications"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Photos"),
                .linkedFramework("CoreLocation"),
                .linkedFramework("BackgroundTasks", .when(platforms: [.iOS]))
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
        )
    ]
)
