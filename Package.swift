// swift-tools-version: 6.3
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
            resources: [
                .copy("Resources/AppIcon.icns")
            ],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("Security"),
                .linkedFramework("CoreLocation")
            ]
        ),
        .testTarget(
            name: "MinuteFlowTests",
            dependencies: ["MinuteFlow"],
            path: "MinuteFlowTests"
        )
    ]
)
