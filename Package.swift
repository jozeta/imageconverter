// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Imageconverter",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "ImageconverterCore"),
        .executableTarget(name: "Imageconverter", dependencies: ["ImageconverterCore"]),
        .testTarget(name: "ImageconverterCoreTests", dependencies: ["ImageconverterCore"]),
    ]
)
