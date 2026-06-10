import CoreGraphics
import XCTest
@testable import PixelWatchAppSupport

final class OverlayAppearanceTests: XCTestCase {
  func testBorderColorMatchesWatcherState() {
    XCTAssertEqual(OverlayAppearance.borderColor(for: .idle), .systemGray)
    XCTAssertEqual(OverlayAppearance.borderColor(for: .armed), .systemGreen)
    XCTAssertEqual(OverlayAppearance.borderColor(for: .triggered), .systemRed)
    XCTAssertEqual(OverlayAppearance.borderColor(for: .errored("bad")), .systemOrange)
  }

  /// CALayer.borderColor expects an RGBA CGColor; a 2-component genericGray CGColor
  /// renders as garbage (was rendering salmon for the .idle state pre-fix).
  func testBorderColorsAreRGBCompatibleForEveryState() {
    let states: [WatcherState] = [.idle, .armed, .triggered, .errored("bad")]
    for state in states {
      let cg = OverlayAppearance.borderColor(for: state).cgColor
      XCTAssertEqual(
        cg.numberOfComponents, 4,
        "border CGColor for \(state) must have 4 components for CALayer; got \(cg.numberOfComponents)"
      )
      XCTAssertEqual(
        cg.colorSpace?.model, .rgb,
        "border CGColor for \(state) must be RGB-modeled for CALayer; got \(String(describing: cg.colorSpace?.model))"
      )
    }
  }
}
