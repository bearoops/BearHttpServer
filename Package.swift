// swift-tools-version: 5.9

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
        .library(
            name: "BearHttpServerRouting",
            targets: ["BearHttpServerRouting"]
        ),
    ],
    targets: [
        .target(
            name: "BearHttpServer",
            path: "BearHttpServer"
        ),
        .target(
            name: "BearHttpServerRouting",
            dependencies: ["BearHttpServer"],
            path: "BearHttpServerRouting"
        ),
        .testTarget(
            name: "BearHttpServerTests",
            dependencies: ["BearHttpServer"],
            path: "BearHttpServerTests",
            resources: [.copy("bear_test.p12")]
        ),
        .testTarget(
            name: "BearHttpServerRoutingTests",
            dependencies: ["BearHttpServerRouting"],
            path: "BearHttpServerRoutingTests"
        ),
    ]
)
