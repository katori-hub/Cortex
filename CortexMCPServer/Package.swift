// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CortexMCPServer",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "CortexMCPServer",
            path: "Sources/CortexMCPServer"
        )
    ]
)
