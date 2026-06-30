// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AIPulse",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0"),
    ],
    targets: [
        .systemLibrary(
            name: "Clibgit2",
            path: "Sources/Clibgit2"
        ),
        .executableTarget(
            name: "AIPulse",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                "Clibgit2",
            ],
            path: "Sources",
            exclude: ["Clibgit2"],
            linkerSettings: [
                .unsafeFlags([
                    "-L/Users/xingyuwang/develop/ai-pulse/mac-app/Libraries/libgit2/lib",
                    "-Xlinker", "-rpath", "-Xlinker", "/Users/xingyuwang/develop/ai-pulse/mac-app/Libraries/libgit2/lib",
                ]),
            ]
        ),
        .testTarget(
            name: "AIPulseTests",
            dependencies: ["AIPulse"],
            path: "Tests"
        ),
    ]
)
