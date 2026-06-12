import AppKit
import CoreGraphics
import XCTest
@testable import PixelWatchAppSupport

@MainActor
final class WatchAreaDrawSessionTests: XCTestCase {
  func testValidDragCompletesWithWindowAndClampedScreenRect() {
    let window = WindowSnapshot(
      windowID: 42,
      processID: 99,
      bundleID: "com.example",
      title: "Editor",
      bounds: CGRect(x: 100, y: 200, width: 300, height: 200),
      isVisible: true
    )
    let session = WatchAreaDrawSession(
      windowResolver: { _, _ in window },
      windowInfoProvider: { [] },
      screenHeightProvider: { 600 },
      ownProcessID: 123
    )

    XCTAssertNil(session.begin(atAppKitPoint: CGPoint(x: 150, y: 350)))
    let result = session.updateAndFinish(atAppKitPoint: CGPoint(x: 460, y: 130))

    XCTAssertEqual(
      result,
      .success(WatchAreaDrawSelection(
        window: window,
        screenRect: CGRect(x: 150, y: 250, width: 250, height: 150)
      ))
    )
  }

  func testInvalidMouseDownReturnsInvalidWindow() {
    let session = WatchAreaDrawSession(
      windowResolver: { _, _ in nil },
      windowInfoProvider: { [] },
      screenHeightProvider: { 600 },
      ownProcessID: 123
    )

    let result = session.begin(atAppKitPoint: CGPoint(x: 150, y: 350))

    XCTAssertEqual(result, .failure(.invalidWindow))
  }

  func testTinySelectionReturnsInvalidSelection() {
    let window = WindowSnapshot(
      windowID: 42,
      processID: 99,
      bundleID: "com.example",
      title: "Editor",
      bounds: CGRect(x: 100, y: 200, width: 300, height: 200),
      isVisible: true
    )
    let session = WatchAreaDrawSession(
      windowResolver: { _, _ in window },
      windowInfoProvider: { [] },
      screenHeightProvider: { 600 },
      ownProcessID: 123
    )

    XCTAssertNil(session.begin(atAppKitPoint: CGPoint(x: 150, y: 350)))
    let result = session.updateAndFinish(atAppKitPoint: CGPoint(x: 154, y: 346))

    XCTAssertEqual(result, .failure(.invalidSelection))
  }

  func testCancelReturnsCancelled() {
    let session = WatchAreaDrawSession(
      windowResolver: { _, _ in nil },
      windowInfoProvider: { [] },
      screenHeightProvider: { 600 },
      ownProcessID: 123
    )

    XCTAssertEqual(session.cancel(), .failure(.cancelled))
  }
}
