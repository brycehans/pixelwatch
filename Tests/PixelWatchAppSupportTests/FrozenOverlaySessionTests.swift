import XCTest
@testable import PixelWatchAppSupport

@MainActor
final class FrozenOverlaySessionTests: XCTestCase {
  func testFrozenRectIsReturnedAsIs() {
    let rect = CGRect(x: 10, y: 20, width: 200, height: 150)
    let session = FrozenOverlaySession(frozenRect: rect)
    XCTAssertEqual(session.frozenRect, rect)
  }

  func testNilFrozenRectIsAllowed() {
    let session = FrozenOverlaySession(frozenRect: nil)
    XCTAssertNil(session.frozenRect)
  }

  func testWaitForFreezeReturnsImmediately() async {
    let session = FrozenOverlaySession(frozenRect: .zero)
    await session.waitForFreeze()
  }
}
