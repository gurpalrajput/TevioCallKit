// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "TevioCallKit",
    platforms: [
        .iOS(.v15)
    ],
    products: [
        .library(
            name: "TevioCallModule",
            targets: ["TevioCallModule"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/AgoraIO/AgoraRtcEngine_iOS.git", from: "4.0.0"),
        .package(url: "https://github.com/socketio/socket.io-client-swift", .upToNextMinor(from: "16.1.1"))
    ],
    targets: [
        .target(
            name: "TevioCallModule",
            dependencies: [
                .product(name: "RtcBasic", package: "AgoraRtcEngine_iOS"),
                .product(name: "SocketIO", package: "socket.io-client-swift")
            ],
            path: "Sources/TevioCallModule",
            resources: [
                .process("Resources")
            ]
        )
    ]
)
