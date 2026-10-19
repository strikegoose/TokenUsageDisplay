// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TokenUsageDisplay",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "TokenUsageDisplay", targets: ["TokenUsageDisplay"])
    ],
    targets: [
        .target(
            name: "TokenUsageCore",
            path: "Sources/TokenUsageCore"
        ),
        .executableTarget(
            name: "TokenUsageDisplay",
            dependencies: ["TokenUsageCore"],
            path: "Sources",
            exclude: ["TokenUsageCore"]
        ),
        .executableTarget(
            name: "TokenUsageSelfTest",
            dependencies: ["TokenUsageCore"],
            path: "Tests/TokenUsageSelfTest"
        )
    ]
)
