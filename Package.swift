// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "FloatyTerm",
    platforms: [
        // macOS 14: minimum for the ScreenCaptureKit APIs the window-mirror tab
        // uses (notably SCStream.updateConfiguration for live, flicker-free resize).
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0")
    ],
    targets: [
        .executableTarget(
            name: "FloatyTerm",
            dependencies: ["SwiftTerm"],
            path: "Sources/FloatyTerm",
            linkerSettings: [.linkedFramework("WebKit")]
        )
    ]
)
