// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MinuteFlow",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MinuteFlow", targets: ["MinuteFlow"])
    ],
    targets: [
        .executableTarget(
            name: "MinuteFlow",
            path: "MinuteFlow",
            exclude: ["Supporting"],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreGraphics")
            ]
        ),
        .testTarget(
            name: "MinuteFlowTests",
            dependencies: ["MinuteFlow"],
            path: "MinuteFlowTests"
        )
    ],
    swiftLanguageModes: [.v6]
)
