// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClaudePet",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure Foundation target — no AppKit, safe to test headlessly
        .target(
            name: "ClaudePetCore",
            path: "Sources/ClaudePetCore"
        ),
        .target(
            name: "ClaudePetLib",
            dependencies: ["ClaudePetCore"],
            path: "Sources/ClaudePetLib"
        ),
        .executableTarget(
            name: "ClaudePet",
            dependencies: ["ClaudePetLib"],
            path: "Sources/ClaudePet"
        ),
        .executableTarget(
            name: "GenerateGifs",
            dependencies: ["ClaudePetLib"],
            path: "Sources/GenerateGifs"
        ),
        .testTarget(
            name: "ClaudePetTests",
            dependencies: ["ClaudePetCore", "ClaudePetLib"],
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
