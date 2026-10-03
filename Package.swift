// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LocalDictation",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "LocalDictation", targets: ["LocalDictation"])],
    targets: [
        .target(name: "DictationCore"),
        .executableTarget(name: "LocalDictation", dependencies: ["DictationCore"],
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("AVFoundation"),
                             .linkedFramework("ApplicationServices"), .linkedFramework("CoreGraphics")]),
        .testTarget(name: "DictationCoreTests", dependencies: ["DictationCore"])
    ]
)
