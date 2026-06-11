import AppKit
import CoreGraphics
import Foundation

// MARK: - Supporting protocols

public protocol AlertPresenting: Sendable {
  @MainActor
  func show(message: String)
}

public protocol OverlaySessionFactory: Sendable {
  @MainActor
  func makeSession(window: WindowSnapshot) -> any WatcherOverlaySession
}

public protocol ConfigureWatcherSheetPresenting: Sendable {
  @MainActor
  func present(draft: WatcherDraft, overlay: any WatcherOverlaySession) async -> Watcher?
}

// MARK: - Coord conversion for persistence

/// Converts a screen-coord rect (the overlay's frozen position) into the
/// window-relative coord system used by `Watcher.rect` and `Capture.crop`.
/// Both inputs must use the same origin convention (top-left for CGWindowList).
public func windowRelativeRect(fromScreen rect: CGRect, windowBounds: CGRect) -> CGRect {
  CGRect(
    x: rect.origin.x - windowBounds.origin.x,
    y: rect.origin.y - windowBounds.origin.y,
    width: rect.width,
    height: rect.height
  )
}

// MARK: - WatcherDraft

public struct WatcherDraft: Sendable {
  public var window: WindowSnapshot
  public var sensitivity: Double
  public var commandMode: CommandMode
  public var armed: Bool

  public init(
    window: WindowSnapshot,
    sensitivity: Double,
    commandMode: CommandMode,
    armed: Bool
  ) {
    self.window = window
    self.sensitivity = sensitivity
    self.commandMode = commandMode
    self.armed = armed
  }
}

// MARK: - Coordinator

@MainActor
public final class NewWatcherCoordinator {
  private let focusedWindowProvider: any FocusedWindowProviding
  private let alertPresenter: any AlertPresenting
  private let overlaySessionFactory: any OverlaySessionFactory
  private let configureSheetPresenter: (any ConfigureWatcherSheetPresenting)?
  private let onWatcherCreated: ((Watcher, any WatcherOverlaySession) -> Void)?

  public init(
    focusedWindowProvider: some FocusedWindowProviding,
    alertPresenter: some AlertPresenting,
    overlaySessionFactory: some OverlaySessionFactory,
    configureSheetPresenter: (any ConfigureWatcherSheetPresenting)? = nil,
    onWatcherCreated: ((Watcher, any WatcherOverlaySession) -> Void)? = nil
  ) {
    self.focusedWindowProvider = focusedWindowProvider
    self.alertPresenter = alertPresenter
    self.overlaySessionFactory = overlaySessionFactory
    self.configureSheetPresenter = configureSheetPresenter
    self.onWatcherCreated = onWatcherCreated
  }

  public func startNewWatcher() async {
    guard let snapshot = focusedWindowProvider.focusedWindow() else {
      alertPresenter.show(message: "PixelWatch could not find a usable focused window.")
      return
    }

    let session = overlaySessionFactory.makeSession(window: snapshot)

    // Wait for the user to click and freeze the overlay before showing the sheet.
    await session.waitForFreeze()

    guard let sheetPresenter = configureSheetPresenter else {
      // No sheet configured — used in test paths that only exercise the overlay start.
      return
    }

    let draft = WatcherDraft(
      window: snapshot,
      sensitivity: 0.5,
      commandMode: .notification(body: "Change found on \(snapshot.title)"),
      armed: false
    )

    guard let watcher = await sheetPresenter.present(draft: draft, overlay: session) else {
      // User cancelled — tear down the overlay session cleanly.
      session.cancel()
      return
    }

    onWatcherCreated?(watcher, session)
  }
}

// MARK: - Live OverlaySessionFactory backed by WatcherOverlayController

/// Wraps a `WatcherOverlayController` so it satisfies `OverlaySessionFactory`.
/// The controller is @MainActor, so this factory is too.
@MainActor
public final class WatcherOverlayControllerSessionFactory: OverlaySessionFactory {
  private let controller: WatcherOverlayController

  public init(controller: WatcherOverlayController) {
    self.controller = controller
  }

  public func makeSession(window: WindowSnapshot) -> any WatcherOverlaySession {
    controller.begin(windowID: window.windowID)
  }
}
