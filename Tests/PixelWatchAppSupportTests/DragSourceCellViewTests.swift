import AppKit
import XCTest
@testable import PixelWatchAppSupport

@MainActor
final class DragSourceCellViewTests: XCTestCase {
  func testFloatingDragVisualDrawsBlackOutlineOutsideWhiteBorder() {
    let view = DragFloatVisualView(frame: NSRect(x: 0, y: 0, width: 50, height: 40))
    let image = render(view)

    let outerStroke = image.colorAt(x: 1, y: 20)!
    let innerStroke = image.colorAt(x: 4, y: 20)!

    XCTAssertLessThan(outerStroke.redComponent, 0.1)
    XCTAssertLessThan(outerStroke.greenComponent, 0.1)
    XCTAssertLessThan(outerStroke.blueComponent, 0.1)
    XCTAssertGreaterThan(outerStroke.alphaComponent, 0.7)

    XCTAssertGreaterThan(innerStroke.redComponent, 0.75)
    XCTAssertGreaterThan(innerStroke.greenComponent, 0.75)
    XCTAssertGreaterThan(innerStroke.blueComponent, 0.75)
    XCTAssertGreaterThan(innerStroke.alphaComponent, 0.7)
  }

  func testEscapeDuringDragCancelsWithoutDropping() {
    let view = DragSourceNSView(frame: NSRect(x: 0, y: 0, width: 50, height: 40))
    var dragStartedCount = 0
    var dropCount = 0
    view.onDragStarted = { dragStartedCount += 1 }
    view.onDrop = { _ in dropCount += 1 }

    view.mouseDown(with: mouseEvent(type: .leftMouseDown, location: NSPoint(x: 5, y: 5)))
    view.mouseDragged(with: mouseEvent(type: .leftMouseDragged, location: NSPoint(x: 20, y: 20)))
    view.keyDown(with: escapeKeyEvent())
    view.mouseUp(with: mouseEvent(type: .leftMouseUp, location: NSPoint(x: 20, y: 20)))

    XCTAssertEqual(dragStartedCount, 1)
    XCTAssertEqual(dropCount, 0)
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

  private func escapeKeyEvent() -> NSEvent {
    NSEvent.keyEvent(
      with: .keyDown,
      location: .zero,
      modifierFlags: [],
      timestamp: 0,
      windowNumber: 0,
      context: nil,
      characters: "\u{1b}",
      charactersIgnoringModifiers: "\u{1b}",
      isARepeat: false,
      keyCode: 53
    )!
  }
}
