// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "mlug",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CGVirtualDisplayPrivate", path: "Sources/CGVirtualDisplayPrivate"),
        .target(
            name: "MlugCore",
            dependencies: ["CGVirtualDisplayPrivate"],
            path: "Sources/MlugCore",
            linkerSettings: [
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreMedia"),
            ]
        ),
        .executableTarget(name: "mlug", dependencies: ["MlugCore"], path: "Sources/mlug"),
        .executableTarget(name: "MlugBar", dependencies: ["MlugCore"], path: "Sources/MlugBar"),
    ]
)
