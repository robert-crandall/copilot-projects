// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "copilot-mux",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.13.0")
    ],
    targets: [
        .target(
            name: "CopilotMuxCore",
            path: "Sources/CopilotMuxCore"
        ),
        .executableTarget(
            name: "copilot-mux",
            dependencies: [
                "CopilotMuxCore",
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ],
            path: "Sources/copilot-mux"
        )
    ]
)
