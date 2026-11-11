// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CutCore",
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [
        .library(name: "CutCore", targets: ["CutCore"])
    ],
    targets: [
        .target(name: "CutCore"),
        .testTarget(name: "CutCoreTests", dependencies: ["CutCore"]),
    ]
)
