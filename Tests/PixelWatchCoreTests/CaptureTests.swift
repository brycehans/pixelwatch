import CoreGraphics
import XCTest
@testable import PixelWatchCore

final class CaptureTests: XCTestCase {
  func testPixelCropRectScalesWindowRelativePointRect() {
    let rect = CaptureGeometry.pixelCropRect(
      windowRelativeRect: CGRect(x: 10, y: 20, width: 30, height: 40),
      scale: 2
    )

    XCTAssertEqual(rect, CGRect(x: 20, y: 40, width: 60, height: 80))
  }

  func testScaleForWindowUsesScreenWithGreatestOverlap() {
    let left = ScreenDescriptor(
      frame: CGRect(x: 0, y: 0, width: 500, height: 500),
      backingScaleFactor: 1
    )
    let right = ScreenDescriptor(
      frame: CGRect(x: 400, y: 0, width: 500, height: 500),
      backingScaleFactor: 2
    )

    let scale = CaptureGeometry.scale(
      forWindowFrame: CGRect(x: 450, y: 100, width: 300, height: 200),
      screens: [left, right]
    )

    XCTAssertEqual(scale, 2)
  }

  func testScaleForWindowFallsBackToMainScreenThenOne() {
    XCTAssertEqual(
      CaptureGeometry.scale(
        forWindowFrame: CGRect(x: 900, y: 900, width: 100, height: 100),
        screens: [
          ScreenDescriptor(
            frame: CGRect(x: 0, y: 0, width: 500, height: 500),
            backingScaleFactor: 2
          ),
        ]
      ),
      2
    )

    XCTAssertEqual(
      CaptureGeometry.scale(
        forWindowFrame: CGRect(x: 900, y: 900, width: 100, height: 100),
        screens: []
      ),
      1
    )
  }
}
