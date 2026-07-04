// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "DrawPadProtocol",
    platforms: [
        .iOS(.v16),
        .macOS(.v12)
    ],
    products: [
        .library(name: "DrawPadProtocol", targets: ["DrawPadProtocol"]),
        .executable(name: "draw-pad-decode", targets: ["draw-pad-decode"])
    ],
    targets: [
        .target(
            name: "DrawPadProtocol",
            path: "Sources/DrawPadProtocol"
        ),
        .executableTarget(
            name: "draw-pad-decode",
            dependencies: ["DrawPadProtocol"],
            path: "Sources/draw-pad-decode"
        ),
        .testTarget(
            name: "DrawPadProtocolTests",
            dependencies: ["DrawPadProtocol"],
            path: "Tests/DrawPadProtocolTests"
        )
    ]
)
