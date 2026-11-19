// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NativeCAM",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "NativeCAM", targets: ["NativeCAM"]),
        .executable(name: "nativecam-cli", targets: ["nativecam-cli"]),
        .library(name: "CAMCore", targets: ["CAMCore"]),
    ],
    targets: [
        // Vendored Clipper2 (Boost license) behind a small C bridge.
        .target(
            name: "CClipper2",
            path: "Sources/CClipper2",
            sources: ["nativecam_clipper.cpp", "clipper2/src"],
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("clipper2/include"),
                .unsafeFlags(["-O3"]),
            ]
        ),
        // Pure-Swift CAM engine: geometry, stock, tools, toolpaths, simulation, Avid Mach4 post.
        .target(
            name: "CAMCore",
            dependencies: ["CClipper2"]
        ),
        // SwiftUI + Metal desktop app.
        .executableTarget(
            name: "NativeCAM",
            dependencies: ["CAMCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Command-line front end: generate G-code from a project file without the UI.
        .executableTarget(
            name: "nativecam-cli",
            dependencies: ["CAMCore"]
        ),
        .testTarget(
            name: "CAMCoreTests",
            dependencies: ["CAMCore"],
            resources: [.copy("Fixtures")]
        ),
    ],
    cxxLanguageStandard: .cxx17
)
