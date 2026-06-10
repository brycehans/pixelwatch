import AppKit
import CoreGraphics
import XCTest
@testable import PixelWatchAppSupport

@MainActor
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

  func testSyncHidesOverlayWhenTargetAppIsNotFrontmost() {
    let overlay = RecordingOverlayWindow()
    let snapshot = WindowSnapshot(
      windowID: 42,
      processID: 99,
      bundleID: "com.example",
      title: "Editor",
      bounds: CGRect(x: 100, y: 100, width: 500, height: 400),
      isVisible: true
    )
    var frontmostPID: pid_t = 99
    let controller = WatcherOverlayController(
      overlayFactory: { _ in overlay },
      mouseLocationProvider: { CGPoint(x: 220, y: 180) },
      windowSnapshotProvider: StubWindowSnapshotProvider(snapshots: [snapshot]),
      frontmostProcessIDProvider: { frontmostPID }
    )

    // begin() emits one setVisible(true). sync() appends one value per call.
    _ = controller.begin(windowID: 42)

    controller.sync()
    XCTAssertEqual(overlay.visibleValues, [true, true])  // target is frontmost → visible

    frontmostPID = 88
    controller.sync()
    XCTAssertEqual(overlay.visibleValues, [true, true, false])  // user Cmd+Tabbed away → hidden

    frontmostPID = 99
    controller.sync()
    XCTAssertEqual(overlay.visibleValues, [true, true, false, true])  // Cmd+Tab back → visible
  }

  // Coord conversion: controller produces top-left-origin frames, NSWindow uses
  // bottom-left. The panel converts at the boundary; this locks the math.
  func testScreenBottomLeftRectConvertsTopLeftFrame() {
    // Cursor visually at TL (700, 500) on a screen of height 1117. The controller
    // would compose a TL frame of (600, 400, 100, 100). NSWindow needs the bottom
    // edge measured from the screen bottom: 1117 - 400 - 100 = 617.
    let bl = screenBottomLeftRect(
      fromTopLeft: CGRect(x: 600, y: 400, width: 100, height: 100),
      screenHeight: 1117
    )
    XCTAssertEqual(bl, CGRect(x: 600, y: 617, width: 100, height: 100))
  }

  func testScreenBottomLeftRectIsInvolutiveOverTwoFlips() {
    // Round-tripping a frame through the conversion twice should return the
    // original — sanity check that the math has no hidden offset.
    let original = CGRect(x: 12, y: 34, width: 56, height: 78)
    let once = screenBottomLeftRect(fromTopLeft: original, screenHeight: 1000)
    let twice = screenBottomLeftRect(fromTopLeft: once, screenHeight: 1000)
    XCTAssertEqual(twice, original)
  }

  func testSyncTranslatesOverlayWhenTargetWindowMoves() {
    let overlay = RecordingOverlayWindow()
    let provider = MutableWindowSnapshotProvider()
    provider.set(
      WindowSnapshot(
        windowID: 42,
        processID: 99,
        bundleID: "com.example",
        title: "Editor",
        bounds: CGRect(x: 100, y: 100, width: 500, height: 400),
        isVisible: true
      )
    )
    let controller = WatcherOverlayController(
      overlayFactory: { _ in overlay },
      mouseLocationProvider: { CGPoint(x: 220, y: 180) },
      windowSnapshotProvider: provider,
      frontmostProcessIDProvider: { 99 }
    )

    let session = controller.begin(windowID: 42)
    // begin sets initial frame at cursor-100,-100 → (120, 80, 100, 100).
    XCTAssertEqual(overlay.frames.last, CGRect(x: 120, y: 80, width: 100, height: 100))

    session.freeze()
    let watcherID = UUID()
    controller.register(watcherID: watcherID, for: session)

    // Window moves by (+50, +30).
    provider.set(
      WindowSnapshot(
        windowID: 42,
        processID: 99,
        bundleID: "com.example",
        title: "Editor",
        bounds: CGRect(x: 150, y: 130, width: 500, height: 400),
        isVisible: true
      )
    )
    controller.sync()
    XCTAssertEqual(overlay.frames.last, CGRect(x: 170, y: 110, width: 100, height: 100))

    // Window moves the other way: net delta from anchor is (-30, -20).
    provider.set(
      WindowSnapshot(
        windowID: 42,
        processID: 99,
        bundleID: "com.example",
        title: "Editor",
        bounds: CGRect(x: 70, y: 80, width: 500, height: 400),
        isVisible: true
      )
    )
    controller.sync()
    XCTAssertEqual(overlay.frames.last, CGRect(x: 90, y: 60, width: 100, height: 100))
  }

  func testSessionCancelHidesOverlayAndStopsTracking() async {
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
    session.cancel()

    // begin() shows the overlay (true), cancel() hides it (false).
    XCTAssertEqual(overlay.visibleValues, [true, false])
    XCTAssertNil(session.frozenRect)
  }
}

private struct StubWindowSnapshotProvider: WindowSnapshotProviding {
  let snapshots: [WindowSnapshot]

  func windowSnapshot(windowID: UInt32) -> WindowSnapshot? {
    snapshots.first { $0.windowID == windowID }
  }
}

/// A snapshot provider whose backing snapshot can be replaced between calls.
/// Tests use it to simulate the target window moving on screen.
private final class MutableWindowSnapshotProvider: WindowSnapshotProviding, @unchecked Sendable {
  private var snapshot: WindowSnapshot?

  func set(_ snapshot: WindowSnapshot) { self.snapshot = snapshot }

  func windowSnapshot(windowID: UInt32) -> WindowSnapshot? {
    guard let s = snapshot, s.windowID == windowID else { return nil }
    return s
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
