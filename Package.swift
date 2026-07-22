// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "copilot-projects",
    platforms: [
        .macOS("26.0"),
        .iOS("17.0"),
    ],
    products: [
        .library(
            name: "CopilotProjectsProtocol",
            targets: ["CopilotProjectsProtocol"]
        ),
    ],
    dependencies: [
        // Pinned past the post-1.13 Metal fixes for stale rows/cursor, window
        // reparenting, synchronized output, and hidden-scroller layout. The
        // temporary fork also carries the Kitty truecolor placeholder ID fix
        // proposed upstream in migueldeicaza/SwiftTerm#607, and a Metal-renderer
        // empty-ink glyph cache (sirfergy/SwiftTerm#1) that keeps blank cells off
        // the per-frame CoreText bounding-box path.
        .package(
            url: "https://github.com/sirfergy/SwiftTerm",
            revision: "78c58c75280fa5c57d96b27d34bc3298ba111a45"
        ),
        .package(
            url: "https://github.com/apple/swift-nio",
            revision: "cd3e1152083706d77b223fb29110e590efcc70c0"
        ),
        .package(
            url: "https://github.com/mochidev/swift-webpush.git",
            exact: "0.4.1"
        ),
    ],
    targets: [
        .target(
            name: "CopilotProjectsProtocol",
            path: "Sources/CopilotProjectsProtocol"
        ),
        .target(
            name: "CopilotProjectsCore",
            dependencies: ["CopilotProjectsProtocol"],
            path: "Sources/CopilotProjectsCore"
        ),
        .executableTarget(
            name: "copilot-projects",
            dependencies: [
                "CopilotProjectsCore",
                "CopilotProjectsProtocol",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "WebPush", package: "swift-webpush")
            ],
            path: "Sources/copilot-projects"
        ),
        .executableTarget(
            name: "copilot-projects-link",
            dependencies: ["CopilotProjectsCore"],
            path: "Sources/copilot-projects-link"
        ),
        .testTarget(
            name: "CopilotProjectsTests",
            dependencies: [
                "CopilotProjectsCore",
                "CopilotProjectsProtocol",
                "copilot-projects",
                .product(name: "WebPush", package: "swift-webpush"),
            ],
            path: "Tests"
        )
    ]
)
