// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "TevioCallKit",
    platforms: [
        .iOS(.v15),
        .macCatalyst(.v15)
    ],
    products: [
        .library(
            name: "TevioCallModule",
            targets: ["TevioCallModule"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/AgoraIO/AgoraRtcEngine_iOS.git", from: "4.0.0"),
        .package(url: "https://github.com/socketio/socket.io-client-swift", .upToNextMinor(from: "16.1.1")),
        .package(url: "https://github.com/scalessec/Toast-Swift.git", from: "5.1.1")
    ],
    targets: [
        .target(
            name: "TevioCallModule",
            dependencies: [
                .product(
                    name: "RtcBasic",
                    package: "AgoraRtcEngine_iOS",
                    condition: .when(platforms: [.iOS])
                ),
                .product(name: "SocketIO", package: "socket.io-client-swift"),
                .product(name: "Toast", package: "Toast-Swift")
            ],
            path: "Sources/TevioCallModule",
            resources: [
                .process("Resources")
            ]
        )
    ]
)
