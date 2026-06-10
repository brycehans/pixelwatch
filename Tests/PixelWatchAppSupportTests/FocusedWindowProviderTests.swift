import CoreGraphics
import XCTest
@testable import PixelWatchAppSupport

final class FocusedWindowProviderTests: XCTestCase {
  func testProviderReturnsFrontmostOnscreenWindow() {
    let provider = CGFocusedWindowProvider(
      frontmostApplication: { FrontmostApp(pid: 99) },
      windowInfoProvider: {
        [
          [
            "kCGWindowOwnerPID": 99,
            "kCGWindowNumber": 42,
            "kCGWindowName": "Editor",
            "kCGWindowBounds": ["X": 10, "Y": 20, "Width": 300, "Height": 200],
            "kCGWindowIsOnscreen": true,
          ],
        ]
      }
    )

    XCTAssertEqual(provider.focusedWindow()?.windowID, 42)
  }
}
