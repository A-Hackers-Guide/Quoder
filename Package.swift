// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Quoder",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Quoder",
            path: "Sources/Quoder",
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Vision"),
                .linkedFramework("ApplicationServices"),
            ]
        )
    ],
    swiftLanguageModes: [.v5]
)
