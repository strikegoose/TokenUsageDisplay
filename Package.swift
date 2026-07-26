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
        .executableTarget(
            name: "TokenUsageDisplay",
            path: "Sources"
        )
    ]
)
