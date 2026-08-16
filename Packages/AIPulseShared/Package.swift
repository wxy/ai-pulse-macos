// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AIPulseShared",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
        .watchOS(.v10),
    ],
    products: [
        .library(name: "AIPulseShared", targets: ["AIPulseShared"]),
    ],
    targets: [
        .target(
            name: "AIPulseShared",
            path: "Sources/AIPulseShared"
        ),
    ]
)
