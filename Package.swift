// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "MediaMemory",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "MediaMemoryApp", targets: ["MediaMemoryApp"]),
        .library(name: "MediaMemoryCore", targets: ["MediaMemoryCore"]),
        .library(name: "MediaMemoryMCPServer", targets: ["MediaMemoryMCPServer"]),
        .executable(name: "media-memory-mcp", targets: ["MediaMemoryMCPTool"])
    ],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(
            name: "MediaMemoryCore",
            dependencies: ["CSQLite"],
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("LocalAuthentication"),
                .linkedFramework("Security"),
                .linkedFramework("Vision"),
                .linkedFramework("Accelerate")
            ]
        ),
        .executableTarget(
            name: "MediaMemoryApp",
            dependencies: ["MediaMemoryCore"],
            linkerSettings: [
                // VideoPlayer 的 SwiftUI 实现继承 AVKit 的 AVPlayerView；
                // 代码没有直接引用 AVKit 符号时 SwiftPM 不会自动链接它，
                // 缺失会在首次实例化 VideoPlayer 时崩溃。
                .linkedFramework("AVKit")
            ]
        ),
        .testTarget(
            name: "MediaMemoryCoreTests",
            dependencies: ["MediaMemoryCore"]
        ),
        .target(
            name: "MediaMemoryMCPServer",
            dependencies: ["MediaMemoryCore"]
        ),
        .executableTarget(
            name: "MediaMemoryMCPTool",
            dependencies: ["MediaMemoryMCPServer"]
        ),
        .testTarget(
            name: "MediaMemoryMCPServerTests",
            dependencies: ["MediaMemoryMCPServer"]
        )
    ]
)
