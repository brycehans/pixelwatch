import CoreGraphics
import XCTest
@testable import PixelWatchAppSupport

final class DropTargetResolverTests: XCTestCase {
  func testResolveAllowsUntitledNormalWindowUnderDropPoint() {
    let resolver = DropTargetResolver(
      ownProcessID: 99,
      bundleIdentifierForProcessID: { pid in
        pid == 42 ? "org.mozilla.firefox" : nil
      }
    )

    let target = resolver.resolve(
      appKitDropPoint: CGPoint(x: 700, y: 700),
      screenHeight: 982,
      windowInfo: [
        windowInfo(
          ownerPID: 99,
          layer: 25,
          windowID: 1,
          title: "Item-0",
          bounds: CGRect(x: 650, y: 240, width: 50, height: 40)
        ),
        windowInfo(
          ownerPID: 42,
          layer: 0,
          windowID: 2,
          title: nil,
          bounds: CGRect(x: 0, y: 38, width: 1512, height: 944)
        ),
      ]
    )

    XCTAssertEqual(
      target,
      WindowSnapshot(
        windowID: 2,
        processID: 42,
        bundleID: "org.mozilla.firefox",
        title: "",
        bounds: CGRect(x: 0, y: 38, width: 1512, height: 944),
        isVisible: true
      )
    )
  }

  private func windowInfo(
    ownerPID: pid_t,
    layer: Int,
    windowID: UInt32,
    title: String?,
    bounds: CGRect
  ) -> [String: Any] {
    var info: [String: Any] = [
      String(kCGWindowOwnerPID): ownerPID,
      String(kCGWindowLayer): layer,
      String(kCGWindowNumber): windowID,
      String(kCGWindowBounds): [
        "X": bounds.origin.x,
        "Y": bounds.origin.y,
        "Width": bounds.width,
        "Height": bounds.height,
      ],
    ]
    if let title {
      info[String(kCGWindowName)] = title
    }
    return info
  }
}
