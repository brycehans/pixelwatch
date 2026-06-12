import CoreGraphics
import XCTest
@testable import PixelWatchAppSupport

final class DrawSelectionTests: XCTestCase {
  func testRectNormalizesDragDownAndRight() {
    let bounds = CGRect(x: 100, y: 200, width: 300, height: 200)

    let rect = DrawSelection.rect(
      from: CGPoint(x: 120, y: 230),
      to: CGPoint(x: 250, y: 310),
      clampedTo: bounds
    )

    XCTAssertEqual(rect, CGRect(x: 120, y: 230, width: 130, height: 80))
  }

  func testRectNormalizesDragUpAndLeft() {
    let bounds = CGRect(x: 100, y: 200, width: 300, height: 200)

    let rect = DrawSelection.rect(
      from: CGPoint(x: 250, y: 310),
      to: CGPoint(x: 120, y: 230),
      clampedTo: bounds
    )

    XCTAssertEqual(rect, CGRect(x: 120, y: 230, width: 130, height: 80))
  }

  func testRectClampsToWindowBounds() {
    let bounds = CGRect(x: 100, y: 200, width: 300, height: 200)

    let rect = DrawSelection.rect(
      from: CGPoint(x: 80, y: 190),
      to: CGPoint(x: 450, y: 430),
      clampedTo: bounds
    )

    XCTAssertEqual(rect, bounds)
  }

  func testRectClampsWhenOnlyEndPointLeavesWindow() {
    let bounds = CGRect(x: 100, y: 200, width: 300, height: 200)

    let rect = DrawSelection.rect(
      from: CGPoint(x: 180, y: 250),
      to: CGPoint(x: 440, y: 430),
      clampedTo: bounds
    )

    XCTAssertEqual(rect, CGRect(x: 180, y: 250, width: 220, height: 150))
  }

  func testMinimumValidSizeIsEightByEight() {
    XCTAssertFalse(DrawSelection.isValid(CGRect(x: 0, y: 0, width: 7.9, height: 20)))
    XCTAssertFalse(DrawSelection.isValid(CGRect(x: 0, y: 0, width: 20, height: 7.9)))
    XCTAssertTrue(DrawSelection.isValid(CGRect(x: 0, y: 0, width: 8, height: 8)))
  }
}
