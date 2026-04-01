// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClawdBar",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure Foundation target — no AppKit, safe to test headlessly
        .target(
            name: "ClawdBarCore",
            path: "Sources/ClawdBarCore"
        ),
        .target(
            name: "ClawdBarLib",
            dependencies: ["ClawdBarCore"],
            path: "Sources/ClawdBarLib"
        ),
        .executableTarget(
            name: "ClawdBar",
            dependencies: ["ClawdBarLib"],
            path: "Sources/ClawdBar"
        ),
        .executableTarget(
            name: "GenerateGifs",
            dependencies: ["ClawdBarLib"],
            path: "Sources/GenerateGifs"
        ),
        .testTarget(
            name: "ClawdBarTests",
            dependencies: ["ClawdBarCore"],
            path: "Tests",
            swiftSettings: [
                .unsafeFlags([
                    "-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
                ])
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                    "-framework", "Testing",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
                ])
            ]
        ),
    ]
)
