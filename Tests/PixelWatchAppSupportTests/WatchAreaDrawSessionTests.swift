import AppKit
import CoreGraphics
import XCTest
@testable import PixelWatchAppSupport

@MainActor
final class WatchAreaDrawSessionTests: XCTestCase {
  func testInitialDrawViewShowsDrawModePromptBeforeWindowSelection() {
    let view = WatchAreaDrawView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
    let image = render(view)

    XCTAssertTrue(containsVisiblePromptBackground(in: image))
  }

  func testDrawViewDimsOutsideHoveredWindowBeforeMouseDown() {
    let view = WatchAreaDrawView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
    view.targetWindowBounds = CGRect(x: 100, y: 80, width: 220, height: 150)
    let image = render(view)

    let outside = image.colorAt(x: 50, y: 100)!
    let inside = image.colorAt(x: 150, y: 100)!

    XCTAssertGreaterThan(outside.alphaComponent, 0.35)
    XCTAssertEqual(inside.alphaComponent, 0, accuracy: 0.01)
  }

  func testHoverBeforeMouseDownResolvesWindowUnderPointer() {
    let window = WindowSnapshot(
      windowID: 42,
      processID: 99,
      bundleID: "com.example",
      title: "Editor",
      bounds: CGRect(x: 100, y: 200, width: 300, height: 200),
      isVisible: true
    )
    let session = WatchAreaDrawSession(
      windowResolver: { point, _ in
        point.x == 150 ? window : nil
      },
      windowInfoProvider: { [] },
      screenHeightProvider: { 600 },
      ownProcessID: 123
    )

    session.updateHover(atAppKitPoint: CGPoint(x: 150, y: 350))

    XCTAssertEqual(session.hoveredWindowForTesting, window)
  }

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

  private func render(_ view: NSView) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
      bitmapDataPlanes: nil,
      pixelsWide: Int(view.bounds.width),
      pixelsHigh: Int(view.bounds.height),
      bitsPerSample: 8,
      samplesPerPixel: 4,
      hasAlpha: true,
      isPlanar: false,
      colorSpaceName: .deviceRGB,
      bytesPerRow: 0,
      bitsPerPixel: 0
    )!
    let context = NSGraphicsContext(bitmapImageRep: rep)!

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    view.draw(view.bounds)
    NSGraphicsContext.restoreGraphicsState()

    return rep
  }

  private func containsVisiblePromptBackground(in image: NSBitmapImageRep) -> Bool {
    for x in 0..<image.pixelsWide {
      for y in 0..<image.pixelsHigh {
        guard let color = image.colorAt(x: x, y: y) else { continue }
        if color.redComponent < 0.1,
           color.greenComponent < 0.1,
           color.blueComponent < 0.1,
           color.alphaComponent > 0.35 {
          return true
        }
      }
    }
    return false
  }
}
