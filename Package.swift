// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "JellyPet",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "JellyCore", targets: ["JellyCore"]),
        .library(name: "JellyMac", targets: ["JellyMac"]),
        .executable(name: "JellyPet", targets: ["JellyApp"])
    ],
    targets: [
        .target(name: "JellyCore"),
        .target(name: "JellyMac", dependencies: ["JellyCore"]),
        .executableTarget(
            name: "JellyApp",
            dependencies: ["JellyCore", "JellyMac"],
            path: "Sources/JellyApp",
            resources: [
                .process("Resources/PetSprites.png"),
                .copy("Resources/JellyPetConfig.json"),
                .copy("Resources/Skills")
            ]
        ),
        .executableTarget(
            name: "JellyBehaviorChecks",
            dependencies: ["JellyCore", "JellyMac"],
            path: "Tests/JellyBehaviorChecks"
        )
    ]
)
