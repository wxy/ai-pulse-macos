// swift-tools-version: 6.0
import Foundation
import PackageDescription

// Resolve the repository root from the manifest's own path so linker flags
// work regardless of the working directory SwiftPM/Xcode invokes the build
// from. `@executable_path`-relative rpaths do not resolve for SwiftPM build
// products (bare executables and .xctest bundles have no app-bundle layout),
// which made `swift test` fail to load libgit2 at runtime.
let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let libgit2LibPath = "\(packageRoot)/Libraries/libgit2/lib"
let libgit2LinkerSettings: [LinkerSetting] = [
    .unsafeFlags([
        "-L\(libgit2LibPath)",
        "-Xlinker", "-rpath", "-Xlinker", libgit2LibPath,
    ]),
]

let package = Package(
    name: "AIPulse",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
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
            resources: [.process("Localizable.xcstrings")],
            linkerSettings: libgit2LinkerSettings
        ),
        .testTarget(
            name: "AIPulseTests",
            dependencies: ["AIPulse", .product(name: "GRDB", package: "GRDB.swift")],
            path: "Tests",
            linkerSettings: libgit2LinkerSettings
        ),
    ]
)
