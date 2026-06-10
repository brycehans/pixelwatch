import CoreGraphics
import XCTest
@testable import PixelWatchAppSupport

@MainActor
final class NewWatcherCoordinatorTests: XCTestCase {
  func testNoFocusedWindowShowsAlertAndStops() async {
    let alert = RecordingAlertPresenter()
    let overlay = RecordingOverlaySessionFactory()
    let coordinator = NewWatcherCoordinator(
      focusedWindowProvider: StubFocusedWindowProvider(window: nil),
      alertPresenter: alert,
      overlaySessionFactory: overlay
    )

    await coordinator.startNewWatcher()

    XCTAssertEqual(alert.messages, ["PixelWatch could not find a usable focused window."])
    XCTAssertEqual(overlay.startedCount, 0)
  }

  func testFocusedWindowStartsOverlayAndConfiguration() async {
    let alert = RecordingAlertPresenter()
    let overlay = RecordingOverlaySessionFactory()
    let sheet = RecordingConfigureWatcherSheetPresenter()
    let coordinator = NewWatcherCoordinator(
      focusedWindowProvider: StubFocusedWindowProvider(
        window: WindowSnapshot(
          windowID: 42,
          processID: 99,
          bundleID: "com.example",
          title: "Editor",
          bounds: CGRect(x: 100, y: 100, width: 500, height: 400),
          isVisible: true
        )
      ),
      alertPresenter: alert,
      overlaySessionFactory: overlay,
      configureSheetPresenter: sheet
    )

    await coordinator.startNewWatcher()

    XCTAssertEqual(alert.messages, [])
    XCTAssertEqual(overlay.startedCount, 1)
    XCTAssertEqual(sheet.presentedCount, 1)
  }

  func testSheetCancelTearsDownOverlaySession() async {
    let alert = RecordingAlertPresenter()
    let overlay = RecordingOverlaySessionFactory()
    // RecordingConfigureWatcherSheetPresenter returns nil by default (user cancel)
    let sheet = RecordingConfigureWatcherSheetPresenter()
    let coordinator = NewWatcherCoordinator(
      focusedWindowProvider: StubFocusedWindowProvider(
        window: WindowSnapshot(
          windowID: 42,
          processID: 99,
          bundleID: "com.example",
          title: "Editor",
          bounds: CGRect(x: 100, y: 100, width: 500, height: 400),
          isVisible: true
        )
      ),
      alertPresenter: alert,
      overlaySessionFactory: overlay,
      configureSheetPresenter: sheet
    )

    await coordinator.startNewWatcher()

    XCTAssertEqual(overlay.lastSession?.cancelCount, 1)
  }
}

private struct StubFocusedWindowProvider: FocusedWindowProviding {
  let window: WindowSnapshot?

  func focusedWindow() -> WindowSnapshot? {
    window
  }
}

@MainActor
private final class RecordingAlertPresenter: AlertPresenting {
  private(set) var messages: [String] = []

  func show(message: String) {
    messages.append(message)
  }
}

@MainActor
private final class RecordingOverlaySessionFactory: OverlaySessionFactory {
  private(set) var startedCount = 0
  private(set) var lastSession: RecordingOverlaySession?

  func makeSession(window: WindowSnapshot) -> any WatcherOverlaySession {
    startedCount += 1
    let session = RecordingOverlaySession(window: window)
    lastSession = session
    return session
  }
}

/// A recording stub for WatcherOverlaySession used in coordinator tests.
/// - `waitForFreeze()` is a no-op so the coordinator proceeds immediately in tests.
/// - `cancel()` increments `cancelCount` so tests can assert it was called.
private final class RecordingOverlaySession: WatcherOverlaySession {
  let window: WindowSnapshot
  private(set) var frozenRect: CGRect?
  private(set) var cancelCount = 0

  init(window: WindowSnapshot) {
    self.window = window
  }

  func freeze() {
    frozenRect = CGRect(x: 0, y: 0, width: 100, height: 100)
  }

  /// No-op — keeps existing test assertions working by returning immediately.
  func cancel() {
    cancelCount += 1
  }

  /// No-op — returns immediately so coordinator tests don't hang waiting for a click.
  func waitForFreeze() async {}
}

@MainActor
private final class RecordingConfigureWatcherSheetPresenter: ConfigureWatcherSheetPresenting {
  private(set) var presentedCount = 0

  func present(draft: WatcherDraft, overlay: any WatcherOverlaySession) async -> Watcher? {
    presentedCount += 1
    _ = draft
    _ = overlay
    return nil
  }
}
