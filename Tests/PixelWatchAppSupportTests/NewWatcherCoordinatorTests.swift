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

  func makeSession(window: WindowSnapshot) -> any WatcherOverlaySession {
    startedCount += 1
    return RecordingOverlaySession(window: window)
  }
}

private final class RecordingOverlaySession: WatcherOverlaySession {
  let window: WindowSnapshot
  private(set) var frozenRect: CGRect?

  init(window: WindowSnapshot) {
    self.window = window
  }

  func freeze() {
    frozenRect = CGRect(x: 0, y: 0, width: 100, height: 100)
  }
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
