import AppKit
import XCTest
@testable import PixelWatchAppSupport
@testable import PixelWatchCore

final class PixelBufferImageTests: XCTestCase {
  func testEmptyBufferReturnsNil() {
    let buf = PixelBuffer(width: 2, height: 2, linearRGB: [])
    XCTAssertNil(buf.displayImage)
  }

  func testZeroDimensionReturnsNil() {
    let buf = PixelBuffer(width: 0, height: 0, linearRGB: [])
    XCTAssertNil(buf.displayImage)
  }

  func testImageDimensionsMatchBuffer() {
    // 2×1 solid black (linear 0,0,0)
    let buf = PixelBuffer(width: 2, height: 1, linearRGB: [Float](repeating: 0, count: 6))
    let img = buf.displayImage
    XCTAssertNotNil(img)
    XCTAssertEqual(img?.size.width, 2)
    XCTAssertEqual(img?.size.height, 1)
  }

  func testFullBrightLinearRGBProducesWhitePixel() {
    // linear 1.0 → sRGB 1.0 → byte 255
    let buf = PixelBuffer(width: 1, height: 1, linearRGB: [1.0, 1.0, 1.0])
    guard let img = buf.displayImage,
          let cgImg = img.cgImage(forProposedRect: nil, context: nil, hints: nil)
    else { XCTFail("no image"); return }

    var rgba = [UInt8](repeating: 0, count: 4)
    let ctx = CGContext(
      data: &rgba, width: 1, height: 1, bitsPerComponent: 8,
      bytesPerRow: 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    )!
    ctx.draw(cgImg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    // Allow ±2 for rounding
    XCTAssertEqual(Int(rgba[0]), 255, accuracy: 2)
    XCTAssertEqual(Int(rgba[1]), 255, accuracy: 2)
    XCTAssertEqual(Int(rgba[2]), 255, accuracy: 2)
  }
}
