// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Oopla",
    // macOS 26 (Tahoe) required for Liquid Glass APIs (GlassEffectContainer,
    // .glassEffect(), .glassEffectID()). Build requires Xcode 26.
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .executable(name: "Oopla", targets: ["Oopla"])
    ],
    targets: [
        .executableTarget(
            name: "Oopla",
            path: ".",
            exclude: [
                ".git",
                "README.md"
            ],
            sources: [
                "App",
                "Features",
                "Core"
            ],
            resources: [
                .copy("Resources")
            ]
        )
    ]
)
