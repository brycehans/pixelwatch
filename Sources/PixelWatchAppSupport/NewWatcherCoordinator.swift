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

// MARK: - WatcherDraft

public struct WatcherDraft: Sendable {
  public var window: WindowSnapshot
  public var name: String
  public var sensitivity: Double
  public var command: String
  public var armed: Bool

  public init(
    window: WindowSnapshot,
    name: String,
    sensitivity: Double,
    command: String,
    armed: Bool
  ) {
    self.window = window
    self.name = name
    self.sensitivity = sensitivity
    self.command = command
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

    guard let sheetPresenter = configureSheetPresenter else {
      // No sheet configured — used in test paths that only exercise the overlay start.
      return
    }

    let draft = WatcherDraft(
      window: snapshot,
      name: snapshot.title,
      sensitivity: 0.5,
      command: "",
      armed: false
    )

    guard let watcher = await sheetPresenter.present(draft: draft, overlay: session) else {
      // User cancelled.
      // TODO: cancel the overlay session when cancel-on-dismiss is wired (Task 5).
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
