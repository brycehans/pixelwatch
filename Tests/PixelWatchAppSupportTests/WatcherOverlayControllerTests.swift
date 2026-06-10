import AppKit
import CoreGraphics
import XCTest
@testable import PixelWatchAppSupport

final class WatcherOverlayControllerTests: XCTestCase {
  func testOverlayFollowsWindowAndFreezesOnClick() async {
    let overlay = RecordingOverlayWindow()
    let controller = WatcherOverlayController(
      overlayFactory: { _ in overlay },
      mouseLocationProvider: { CGPoint(x: 220, y: 180) },
      windowSnapshotProvider: StubWindowSnapshotProvider(
        snapshots: [
          WindowSnapshot(
            windowID: 42,
            processID: 99,
            bundleID: "com.example",
            title: "Editor",
            bounds: CGRect(x: 100, y: 100, width: 500, height: 400),
            isVisible: true
          )
        ]
      )
    )

    let session = controller.begin(windowID: 42)
    XCTAssertEqual(overlay.frames.first, CGRect(x: 120, y: 80, width: 100, height: 100))
    session.freeze()
    XCTAssertEqual(session.frozenRect, CGRect(x: 120, y: 80, width: 100, height: 100))
  }
}

private struct StubWindowSnapshotProvider: WindowSnapshotProviding {
  let snapshots: [WindowSnapshot]

  func windowSnapshot(windowID: UInt32) -> WindowSnapshot? {
    snapshots.first { $0.windowID == windowID }
  }
}

private final class RecordingOverlayWindow: WatcherOverlayWindow {
  private(set) var frames: [CGRect] = []
  private(set) var borderColors: [NSColor] = []
  private(set) var visibleValues: [Bool] = []

  func setFrame(_ frame: CGRect) {
    frames.append(frame)
  }

  func setBorderColor(_ color: NSColor) {
    borderColors.append(color)
  }

  func setVisible(_ visible: Bool) {
    visibleValues.append(visible)
  }
}
