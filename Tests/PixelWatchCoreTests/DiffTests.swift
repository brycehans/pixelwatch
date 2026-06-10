import CoreGraphics
import XCTest
@testable import PixelWatchCore

final class DiffTests: XCTestCase {
  func testIdenticalImagesScoreZero() {
    let image = makeImage(width: 2, height: 2) { _ in (10, 20, 30, 255) }
    let baseline = Diff.makeBuffer(from: image)
    let current = Diff.makeBuffer(from: image)

    XCTAssertEqual(Diff.score(baseline: baseline, current: current), 0)
  }

  func testSinglePixelChangeScoresOnePixelFraction() {
    let baselineImage = makeImage(width: 2, height: 2) { _ in (0, 0, 0, 255) }
    let currentImage = makeImage(width: 2, height: 2) { index in
      index == 3 ? (255, 255, 255, 255) : (0, 0, 0, 255)
    }
    let baseline = Diff.makeBuffer(from: baselineImage)
    let current = Diff.makeBuffer(from: currentImage)

    XCTAssertEqual(Diff.score(baseline: baseline, current: current), 0.25, accuracy: 0.0001)
  }

  private func makeImage(
    width: Int,
    height: Int,
    pixel: (Int) -> (UInt8, UInt8, UInt8, UInt8)
  ) -> CGImage {
    var rgba = [UInt8]()
    rgba.reserveCapacity(width * height * 4)
    for index in 0..<(width * height) {
      let value = pixel(index)
      rgba.append(value.0)
      rgba.append(value.1)
      rgba.append(value.2)
      rgba.append(value.3)
    }
    let provider = CGDataProvider(data: Data(rgba) as CFData)!
    return CGImage(
      width: width,
      height: height,
      bitsPerComponent: 8,
      bitsPerPixel: 32,
      bytesPerRow: width * 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
      provider: provider,
      decode: nil,
      shouldInterpolate: false,
      intent: .defaultIntent
    )!
  }
}
