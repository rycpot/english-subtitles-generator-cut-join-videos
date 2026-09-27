// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "EnglishSubtitleMaker",
    platforms: [.macOS(.v12)],
    targets: [
        // Pure logic: ffmpeg output parsing, chunk planning, Groq types, SRT building.
        .target(name: "SubtitleCore"),
        // The macOS app (SwiftUI) plus the process/network plumbing.
        .executableTarget(name: "EnglishSubtitleMaker", dependencies: ["SubtitleCore"]),
        .testTarget(name: "SubtitleCoreTests", dependencies: ["SubtitleCore"]),
    ]
)
