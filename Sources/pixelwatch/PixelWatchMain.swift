import AppKit
import Foundation
import PixelWatchAppSupport
import PixelWatchCore

@main
enum PixelWatchMain {
  @MainActor
  private static var delegate: PixelWatchAppDelegate?

  @MainActor
  static func main() {
    let app = NSApplication.shared
    let delegate = PixelWatchAppDelegate()
    Self.delegate = delegate
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
  }
}

// MARK: - NSAlert-backed alert presenter

private struct NSAlertPresenter: AlertPresenting {
  @MainActor
  func show(message: String) {
    let alert = NSAlert()
    alert.messageText = message
    alert.alertStyle = .informational
    alert.runModal()
  }
}

// MARK: - App delegate

@MainActor
private final class PixelWatchAppDelegate: NSObject, NSApplicationDelegate {
  private let bus = EventBus()
  private lazy var store = WatcherStore(bus: bus)
  private let persistence = WatcherPersistence(url: PixelWatchAppDelegate.watchersURL)
  private var watchers: [Watcher] = []
  private var stageTasks: [Task<Void, Never>] = []
  private var eventTask: Task<Void, Never>?
  private var statusItem: NSStatusItem?
  private var lastEventDescription = "No events yet"

  private let overlayController = WatcherOverlayController()
  private var syncTimer: Timer?
  private var debugSocket: DebugSocket?
  private lazy var coordinator: NewWatcherCoordinator = {
    let factory = WatcherOverlayControllerSessionFactory(controller: overlayController)
    let sheetPresenter = AppKitConfigureWatcherSheetPresenter()
    return NewWatcherCoordinator(
      focusedWindowProvider: CGFocusedWindowProvider(),
      alertPresenter: NSAlertPresenter(),
      overlaySessionFactory: factory,
      configureSheetPresenter: sheetPresenter,
      onWatcherCreated: { [weak self] watcher, session in
        guard let self else { return }
        self.handleWatcherCreated(watcher, session: session)
      }
    )
  }()

  func applicationDidFinishLaunching(_: Notification) {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    statusItem?.button?.title = "PixelWatch"
    startRuntime()
    startSyncTimer()
    refreshMenu()

    // Start the debug socket unconditionally.
    // TODO: Replace with a Settings toggle before shipping — this should be off by default.
    let socket = DebugSocket(bus: bus, commandHandler: { [weak self] cmd in
      Task { @MainActor [weak self] in self?.handle(command: cmd) }
    })
    self.debugSocket = socket
    Task {
      do {
        try await socket.start()
        NSLog("DebugSocket listening at %@", DebugSocket.defaultPath().path)
      } catch {
        NSLog("DebugSocket failed to start: %@", error.localizedDescription)
      }
    }
  }

  func applicationWillTerminate(_: Notification) {
    syncTimer?.invalidate()
    syncTimer = nil
    stageTasks.forEach { $0.cancel() }
    eventTask?.cancel()
    Task { await debugSocket?.stop() }
  }

  private func startSyncTimer() {
    syncTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.overlayController.sync() }
    }
  }

  @objc private func newWatcherClicked(_: AnyObject?) {
    Task { await coordinator.startNewWatcher() }
  }

  /// Dispatches a DebugSocket command to its UI side-effect. Runs on the main actor
  /// because `coordinator.startNewWatcher()` and `NSApp.terminate` both require it.
  private func handle(command: DebugCommand) {
    switch command {
    case .newWatcher:
      newWatcherClicked(nil)
    case .quit:
      NSApp.terminate(nil)
    }
  }

  private func handleWatcherCreated(_ watcher: Watcher, session: any WatcherOverlaySession) {
    watchers.append(watcher)
    do {
      try persistence.save(watchers)
    } catch {
      lastEventDescription = "Failed to save watcher: \(error)"
    }

    Task {
      await store.add(watcher)
      if watcher.armed {
        await WatcherArmService.arm(watcherID: watcher.id, bus: bus, store: store)
      }
      overlayController.register(watcherID: watcher.id, for: session)
      await MainActor.run { refreshMenu() }
    }
  }

  private func startRuntime() {
    do {
      watchers = try persistence.load()
    } catch {
      lastEventDescription = "Failed to load watchers: \(error)"
      watchers = []
    }

    let loadedWatchers = watchers
    Task {
      for watcher in loadedWatchers {
        await store.add(watcher)
      }
      await store.start()
      stageTasks = [
        CaptureStage.start(bus: bus, store: store),
        DiffStage.start(bus: bus, store: store),
        DecideStage.start(bus: bus, store: store),
        HookStage.start(bus: bus, store: store),
      ]
      startEventMonitor()

      // Restore overlays for each disk-loaded watcher whose target window is
      // currently on screen. Without this, sync()'s window-follow logic never
      // sees these watchers — they have no entry in the controller.
      let candidates = LiveWindowCandidateProvider().candidates()
      await MainActor.run {
        for watcher in loadedWatchers {
          guard let candidate = WindowResolver.resolve(
            binding: watcher.target,
            candidates: candidates
          ) else { continue }
          overlayController.restore(
            watcherID: watcher.id,
            windowID: candidate.windowID,
            windowRelativeRect: watcher.rect,
            state: watcher.armed ? .armed : .idle
          )
        }
      }

      for watcher in loadedWatchers where watcher.armed {
        await WatcherArmService.arm(watcherID: watcher.id, bus: bus, store: store)
      }
      await MainActor.run { refreshMenu() }
    }
  }

  private func startEventMonitor() {
    eventTask = Task {
      var events = await bus.subscribe().makeAsyncIterator()
      while !Task.isCancelled, let event = await events.next() {
        let watcherID = event.watcherID
        // Re-fetch state after the event so we read post-apply state.
        // Note: WatcherStore and the delegate subscribe independently, so there
        // is a small race where the store may not yet have applied the event;
        // in practice the dictionary update is instantaneous and the lag is not
        // observable at the 4 Hz sync cadence.
        let state = await store.state(for: watcherID)
        await MainActor.run {
          lastEventDescription = Self.describe(event)
          refreshMenu()
          if let state {
            overlayController.update(watcherID: watcherID, state: state)
          }
        }
      }
    }
  }

  private func refreshMenu() {
    let menu = NSMenu()
    let title = NSMenuItem(title: "PixelWatch", action: nil, keyEquivalent: "")
    title.isEnabled = false
    menu.addItem(title)
    menu.addItem(NSMenuItem(
      title: "\(watchers.count) watcher\(watchers.count == 1 ? "" : "s") loaded",
      action: nil,
      keyEquivalent: ""
    ))
    menu.addItem(NSMenuItem(title: lastEventDescription, action: nil, keyEquivalent: ""))
    menu.addItem(.separator())
    let newWatcher = NSMenuItem(
      title: "+ New watcher",
      action: #selector(newWatcherClicked(_:)),
      keyEquivalent: "n"
    )
    newWatcher.target = self
    menu.addItem(newWatcher)
    menu.addItem(.separator())
    menu.addItem(NSMenuItem(
      title: "Quit PixelWatch",
      action: #selector(NSApplication.terminate(_:)),
      keyEquivalent: "q"
    ))
    statusItem?.menu = menu
  }

  private static func describe(_ event: PixelWatchEvent) -> String {
    switch event {
    case .armed:
      "Armed"
    case .frameCaptured:
      "Frame captured"
    case let .diffComputed(_, score, _):
      "Diff score \(format(score))"
    case let .thresholdExceeded(_, score, _):
      "Fired at score \(format(score))"
    case let .windowVanished(_, reason):
      "Window vanished: \(reason)"
    case let .hookStarted(_, _, reason):
      "Hook started: \(reason)"
    case let .hookFinished(_, exit, _, _):
      "Hook finished: \(exit)"
    case .paused:
      "Paused"
    case let .errored(_, message):
      "Error: \(message)"
    }
  }

  private static func format(_ value: Double) -> String {
    String(format: "%.4f", value)
  }

  private static var watchersURL: URL {
    FileManager.default
      .homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/PixelWatch/watchers.json")
  }
}
