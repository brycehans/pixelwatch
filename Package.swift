// swift-tools-version:6.0
import PackageDescription

let package = Package(
  name: "pixelwatch-bench",
  platforms: [.macOS(.v15)],
  targets: [
    .executableTarget(
      name: "pixelwatch-bench",
      path: "Sources/pixelwatch-bench"
    ),
  ]
)
