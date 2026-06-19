// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "copilot-projects",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.13.0")
    ],
    targets: [
        .target(
            name: "CopilotProjectsCore",
            path: "Sources/CopilotProjectsCore"
        ),
        .executableTarget(
            name: "copilot-projects",
            dependencies: [
                "CopilotProjectsCore",
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ],
            path: "Sources/copilot-projects"
        )
    ]
)
