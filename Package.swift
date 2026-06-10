// swift-tools-version:6.0
import PackageDescription

let package = Package(
  name: "PixelWatch",
  platforms: [.macOS(.v15)],
  products: [
    .library(name: "PixelWatchCore", targets: ["PixelWatchCore"]),
    .library(name: "PixelWatchAppSupport", targets: ["PixelWatchAppSupport"]),
    .executable(name: "pixelwatch", targets: ["pixelwatch"]),
    .executable(name: "pixelwatch-bench", targets: ["pixelwatch-bench"]),
  ],
  targets: [
    .target(
      name: "PixelWatchCore",
      path: "Sources/PixelWatchCore"
    ),
    .target(
      name: "PixelWatchAppSupport",
      dependencies: ["PixelWatchCore"],
      path: "Sources/PixelWatchAppSupport"
    ),
    .executableTarget(
      name: "pixelwatch",
      dependencies: ["PixelWatchCore", "PixelWatchAppSupport"],
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
    .testTarget(
      name: "PixelWatchAppSupportTests",
      dependencies: ["PixelWatchAppSupport"],
      path: "Tests/PixelWatchAppSupportTests"
    ),
  ]
)
