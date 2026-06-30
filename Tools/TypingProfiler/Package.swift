// swift-tools-version:5.9
import PackageDescription

// Standalone, isolated from FloatyTerm's package on purpose: this is a one-off
// recorder you run to build a keystroke-dynamics profile. Build/run with:
//   cd Tools/TypingProfiler && swift run
let package = Package(
    name: "TypingProfiler",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "typing-profiler", path: "Sources/typing-profiler")
    ]
)
