// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WhisperApp",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "WhisperApp", targets: ["WhisperApp"]),
    ],
    targets: [
        .executableTarget(name: "WhisperApp"),
        .testTarget(name: "WhisperAppTests", dependencies: ["WhisperApp"]),
    ]
)
