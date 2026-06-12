import AppKit
import XCTest
@testable import PixelWatchAppSupport

@MainActor
final class DragSourceCellViewTests: XCTestCase {
  func testPlusControlDrawsBorderAndPlus() {
    let view = DragSourceNSView(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
    let image = render(view)

    let border = image.colorAt(x: 2, y: 14)!
    let center = image.colorAt(x: 14, y: 14)!

    XCTAssertGreaterThan(border.alphaComponent, 0.1)
    XCTAssertGreaterThan(center.alphaComponent, 0.1)
  }

  func testMouseUpCallsClickOnce() {
    let view = DragSourceNSView(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
    var clickCount = 0
    view.onClick = { clickCount += 1 }

    view.mouseDown(with: mouseEvent(type: .leftMouseDown, location: NSPoint(x: 5, y: 5)))
    view.mouseUp(with: mouseEvent(type: .leftMouseUp, location: NSPoint(x: 5, y: 5)))

    XCTAssertEqual(clickCount, 1)
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

  private func mouseEvent(type: NSEvent.EventType, location: NSPoint) -> NSEvent {
    NSEvent.mouseEvent(
      with: type,
      location: location,
      modifierFlags: [],
      timestamp: 0,
      windowNumber: 0,
      context: nil,
      eventNumber: 0,
      clickCount: 1,
      pressure: 1
    )!
  }
}
