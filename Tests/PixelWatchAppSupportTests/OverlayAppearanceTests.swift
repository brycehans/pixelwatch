import CoreGraphics
import XCTest
@testable import PixelWatchAppSupport

final class OverlayAppearanceTests: XCTestCase {
  func testBorderColorMatchesWatcherState() {
    XCTAssertEqual(OverlayAppearance.borderColor(for: .idle), .gray)
    XCTAssertEqual(OverlayAppearance.borderColor(for: .armed), .systemGreen)
    XCTAssertEqual(OverlayAppearance.borderColor(for: .triggered), .systemRed)
    XCTAssertEqual(OverlayAppearance.borderColor(for: .errored("bad")), .systemOrange)
  }
}
