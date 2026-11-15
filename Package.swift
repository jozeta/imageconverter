// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Imageconverter",
    platforms: [.macOS(.v14)],
    products: [
        // Not "imageconverter": on a case-insensitive volume that is the same file as the app's "Imageconverter".
        // The release script installs it as `imageconverter`.
        .executable(name: "imageconverter-cli", targets: ["ImageconverterCLI"]),
        // The update installer XPC service; the release script puts it in Contents/XPCServices.
        .executable(name: "imageconverter-installer", targets: ["ImageconverterInstaller"]),
    ],
    targets: [
        .target(name: "ImageconverterCore"),
        .executableTarget(name: "Imageconverter", dependencies: ["ImageconverterCore"]),
        // The command line's parser and commands live in a library so tests can call them without a process.
        .target(name: "ImageconverterCLIKit", dependencies: ["ImageconverterCore"]),
        .executableTarget(name: "ImageconverterCLI", dependencies: ["ImageconverterCLIKit"]),
        // The installer service's logic in a library so tests can call it without XPC; the executable is a thin wrapper.
        .target(name: "ImageconverterInstallerKit", dependencies: ["ImageconverterCore"]),
        .executableTarget(name: "ImageconverterInstaller", dependencies: ["ImageconverterInstallerKit"]),
        .testTarget(name: "ImageconverterCoreTests", dependencies: ["ImageconverterCore"]),
        .testTarget(name: "ImageconverterInstallerTests", dependencies: ["ImageconverterInstallerKit", "ImageconverterCore"]),
        .testTarget(name: "ImageconverterCLITests", dependencies: ["ImageconverterCLIKit", "ImageconverterCore"]),
    ]
)
