// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "YTDownloader",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "YTDownloader", path: "Sources/YTDownloader")
    ]
)
