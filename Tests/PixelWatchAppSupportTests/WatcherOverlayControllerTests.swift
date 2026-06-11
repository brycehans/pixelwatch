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
    XCTAssertEqual(overlay.frames.first, CGRect(x: 170, y: 140, width: 50, height: 40))
    session.freeze()
    XCTAssertEqual(session.frozenRect, CGRect(x: 170, y: 140, width: 50, height: 40))
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
    // begin sets initial frame at cursor-50,-40 → (170, 140, 50, 40).
    XCTAssertEqual(overlay.frames.last, CGRect(x: 170, y: 140, width: 50, height: 40))

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
    XCTAssertEqual(overlay.frames.last, CGRect(x: 220, y: 170, width: 50, height: 40))

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
    XCTAssertEqual(overlay.frames.last, CGRect(x: 140, y: 120, width: 50, height: 40))
  }

  // If the user moves the target window between clicking-to-freeze and saving
  // the configure sheet, the anchor must reflect the bounds at freeze time,
  // not register time. Otherwise the overlay will be off by the intervening
  // delta the moment sync() first runs.
  func testAnchorBoundsAreCapturedAtFreezeNotRegister() {
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
    session.freeze()  // captures anchorBounds = (100, 100, ...)

    // User dawdles on the configure sheet; the target window is dragged.
    provider.set(
      WindowSnapshot(
        windowID: 42,
        processID: 99,
        bundleID: "com.example",
        title: "Editor",
        bounds: CGRect(x: 300, y: 300, width: 500, height: 400),
        isVisible: true
      )
    )

    let watcherID = UUID()
    controller.register(watcherID: watcherID, for: session)

    // Window moves once more before the next sync tick.
    provider.set(
      WindowSnapshot(
        windowID: 42,
        processID: 99,
        bundleID: "com.example",
        title: "Editor",
        bounds: CGRect(x: 400, y: 400, width: 500, height: 400),
        isVisible: true
      )
    )
    controller.sync()

    // Anchor was (100, 100); current is (400, 400); delta = (+300, +300).
    // anchorRect (frozenRect) = (170, 140). Translated: (470, 440).
    // Pre-fix this would have computed delta from (300, 300), giving (270, 240).
    XCTAssertEqual(overlay.frames.last, CGRect(x: 470, y: 440, width: 50, height: 40))
  }

  // Disk-loaded watchers need overlay entries; otherwise sync()'s window-follow
  // logic never runs for them.
  func testRestoreCreatesEntryThatFollowsWindowMoves() {
    let overlay = RecordingOverlayWindow()
    let provider = MutableWindowSnapshotProvider()
    provider.set(
      WindowSnapshot(
        windowID: 42,
        processID: 99,
        bundleID: "com.example",
        title: "Editor",
        bounds: CGRect(x: 200, y: 100, width: 800, height: 600),
        isVisible: true
      )
    )
    let controller = WatcherOverlayController(
      overlayFactory: { _ in overlay },
      mouseLocationProvider: { .zero },
      windowSnapshotProvider: provider,
      frontmostProcessIDProvider: { 99 }
    )

    let watcherID = UUID()
    // window-relative (50, 60, 100, 100) inside window at (200, 100, ...) →
    // initial screen rect = (250, 160, 100, 100). Border = armed (systemGreen).
    controller.restore(
      watcherID: watcherID,
      windowID: 42,
      windowRelativeRect: CGRect(x: 50, y: 60, width: 100, height: 100),
      state: .armed
    )
    XCTAssertEqual(overlay.frames.last, CGRect(x: 250, y: 160, width: 100, height: 100))
    XCTAssertEqual(overlay.borderColors.last, .systemGreen)

    // Window moves by (+30, +20). sync() should translate.
    provider.set(
      WindowSnapshot(
        windowID: 42,
        processID: 99,
        bundleID: "com.example",
        title: "Editor",
        bounds: CGRect(x: 230, y: 120, width: 800, height: 600),
        isVisible: true
      )
    )
    controller.sync()
    XCTAssertEqual(overlay.frames.last, CGRect(x: 280, y: 180, width: 100, height: 100))
  }

  func testRestoreSkipsWatchersWhoseWindowCannotBeResolved() {
    let overlay = RecordingOverlayWindow()
    let provider = MutableWindowSnapshotProvider()   // empty by default
    let controller = WatcherOverlayController(
      overlayFactory: { _ in overlay },
      mouseLocationProvider: { .zero },
      windowSnapshotProvider: provider,
      frontmostProcessIDProvider: { 99 }
    )
    controller.restore(
      watcherID: UUID(),
      windowID: 42,
      windowRelativeRect: CGRect(x: 0, y: 0, width: 50, height: 50),
      state: .idle
    )
    XCTAssertTrue(overlay.frames.isEmpty, "no overlay should be created when the window isn't resolvable")
  }

  func testOverlayLabelReflectsStateAcrossBeginAndUpdate() {
    let overlay = RecordingOverlayWindow()
    let snapshot = WindowSnapshot(
      windowID: 42,
      processID: 99,
      bundleID: "com.example",
      title: "Editor",
      bounds: CGRect(x: 100, y: 100, width: 500, height: 400),
      isVisible: true
    )
    let controller = WatcherOverlayController(
      overlayFactory: { _ in overlay },
      mouseLocationProvider: { CGPoint(x: 220, y: 180) },
      windowSnapshotProvider: StubWindowSnapshotProvider(snapshots: [snapshot]),
      frontmostProcessIDProvider: { 99 }
    )

    let session = controller.begin(windowID: 42)
    XCTAssertEqual(overlay.labelTexts, ["idle"])

    session.freeze()
    let watcherID = UUID()
    controller.register(watcherID: watcherID, for: session)
    controller.update(watcherID: watcherID, state: .armed)
    XCTAssertEqual(overlay.labelTexts, ["idle", "armed"])

    controller.update(watcherID: watcherID, state: .triggered)
    controller.update(watcherID: watcherID, state: .errored("scratched"))
    XCTAssertEqual(overlay.labelTexts, ["idle", "armed", "triggered", "errored"])
  }

  func testRestoreSetsLabelToInitialState() {
    let overlay = RecordingOverlayWindow()
    let snapshot = WindowSnapshot(
      windowID: 42,
      processID: 99,
      bundleID: "com.example",
      title: "Editor",
      bounds: CGRect(x: 200, y: 100, width: 800, height: 600),
      isVisible: true
    )
    let controller = WatcherOverlayController(
      overlayFactory: { _ in overlay },
      mouseLocationProvider: { .zero },
      windowSnapshotProvider: StubWindowSnapshotProvider(snapshots: [snapshot]),
      frontmostProcessIDProvider: { 99 }
    )

    controller.restore(
      watcherID: UUID(),
      windowID: 42,
      windowRelativeRect: CGRect(x: 0, y: 0, width: 50, height: 50),
      state: .armed
    )
    XCTAssertEqual(overlay.labelTexts, ["armed"])
  }

  func testRemoveHidesOverlayAndDropsEntry() {
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
    session.freeze()
    let watcherID = UUID()
    controller.register(watcherID: watcherID, for: session)

    controller.remove(watcherID: watcherID)

    // begin shows true; remove hides it
    XCTAssertEqual(overlay.visibleValues.last, false)
    // sync() should no-op for removed watcher — no new frames
    controller.sync()
    XCTAssertEqual(overlay.frames.count, 1, "sync should not update a removed watcher's overlay")
  }

  func testRemoveIsNoOpForUnknownWatcherID() {
    let controller = WatcherOverlayController(
      overlayFactory: { _ in RecordingOverlayWindow() },
      mouseLocationProvider: { .zero },
      windowSnapshotProvider: StubWindowSnapshotProvider(snapshots: [])
    )
    // Must not crash
    controller.remove(watcherID: UUID())
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
  private(set) var labelTexts: [String] = []

  func setFrame(_ frame: CGRect) {
    frames.append(frame)
  }

  func setBorderColor(_ color: NSColor) {
    borderColors.append(color)
  }

  func setVisible(_ visible: Bool) {
    visibleValues.append(visible)
  }

  func setLabelText(_ text: String) {
    labelTexts.append(text)
  }
}
