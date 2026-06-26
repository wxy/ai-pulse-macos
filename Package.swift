// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AIPulse",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0"),
    ],
    targets: [
        .executableTarget(
            name: "AIPulse",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources"
        ),
        .testTarget(
            name: "AIPulseTests",
            dependencies: ["AIPulse"],
            path: "Tests"
        ),
    ]
)
