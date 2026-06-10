// swift-tools-version:6.0
import PackageDescription

let package = Package(
  name: "PixelWatch",
  platforms: [.macOS(.v15)],
  products: [
    .library(name: "PixelWatchCore", targets: ["PixelWatchCore"]),
    .executable(name: "pixelwatch", targets: ["pixelwatch"]),
    .executable(name: "pixelwatch-bench", targets: ["pixelwatch-bench"]),
  ],
  targets: [
    .target(
      name: "PixelWatchCore",
      path: "Sources/PixelWatchCore"
    ),
    .executableTarget(
      name: "pixelwatch",
      dependencies: ["PixelWatchCore"],
      path: "Sources/pixelwatch"
    ),
    .executableTarget(
      name: "pixelwatch-bench",
      path: "Sources/pixelwatch-bench"
    ),
    .testTarget(
      name: "PixelWatchCoreTests",
      dependencies: ["PixelWatchCore"],
      path: "Tests/PixelWatchCoreTests"
    ),
  ]
)
