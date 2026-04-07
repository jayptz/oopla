// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Oopla",
    platforms: [
        .macOS(.v13)
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
