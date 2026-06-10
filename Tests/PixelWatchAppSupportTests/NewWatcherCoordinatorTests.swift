import CoreGraphics
import XCTest
@testable import PixelWatchAppSupport

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
}

private struct StubFocusedWindowProvider: FocusedWindowProviding {
  let window: WindowSnapshot?

  func focusedWindow() -> WindowSnapshot? {
    window
  }
}

private final class RecordingAlertPresenter: AlertPresenting {
  private(set) var messages: [String] = []

  func show(message: String) {
    messages.append(message)
  }
}

private final class RecordingOverlaySessionFactory: OverlaySessionFactory {
  private(set) var startedCount = 0

  func makeSession(window: WindowSnapshot) -> WatcherOverlaySession {
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
