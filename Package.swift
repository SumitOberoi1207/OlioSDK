// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OlioSDK",
    platforms: [
        .iOS(.v16),
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "OlioSDK",
            targets: ["OlioSDK"]
        )
    ],
    targets: [
        .target(
            name: "OlioSDK",
            path: "Sources/OlioSDK"
        ),
        .testTarget(
            name: "OlioSDKTests",
            dependencies: ["OlioSDK"],
            path: "Tests/OlioSDKTests"
        )
    ]
)
