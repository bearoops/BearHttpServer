// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "BearHttpServer",
    platforms: [
        .macOS(.v11),
        .iOS(.v15),
        .tvOS(.v15),
        .visionOS(.v1),
    ],
    products: [
        .library(
            name: "BearHttpServer",
            targets: ["BearHttpServer"]
        ),
    ],
    targets: [
        .target(
            name: "BearHttpServer",
            path: "BearHttpServer"
        ),
        .testTarget(
            name: "BearHttpServerTests",
            dependencies: ["BearHttpServer"],
            path: "BearHttpServerTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
