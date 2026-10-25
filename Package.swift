// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TMSkipper",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "tmskipper", targets: ["tmskipper"]),
    ],
    targets: [
        .target(name: "TMSkipperCore"),
        .executableTarget(name: "tmskipper", dependencies: ["TMSkipperCore"]),
        .testTarget(name: "TMSkipperCoreTests", dependencies: ["TMSkipperCore"]),
    ]
)
