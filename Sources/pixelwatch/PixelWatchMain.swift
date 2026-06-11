import AppKit
import Foundation
import PixelWatchAppSupport
import PixelWatchCore
import SwiftUI

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

  private let popoverModel = PopoverModel()
  private lazy var popoverController: NSHostingController<PopoverGridView> = {
    NSHostingController(rootView: PopoverGridView(
      model: popoverModel,
      onDelete: { [weak self] id in self?.handleDeleteWatcher(id: id) },
      onDrop: { [weak self] point in self?.handleDrop(at: point) },
      onDragStarted: { [weak self] in self?.popover.behavior = .applicationDefined },
      onQuit: { NSApp.terminate(nil) }
    ))
  }()
  private lazy var popover: NSPopover = {
    let p = NSPopover()
    p.contentViewController = popoverController
    p.behavior = .transient
    return p
  }()

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
    statusItem?.button?.title = "PW"
    statusItem?.button?.action = #selector(togglePopover(_:))
    statusItem?.button?.target = self
    startRuntime()
    startSyncTimer()
    Task { await self.refreshPopover() }

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

  @objc private func togglePopover(_ sender: AnyObject?) {
    guard let button = statusItem?.button else { return }
    if popover.isShown {
      popover.performClose(sender)
    } else {
      popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
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
    case let .dropAt(x, y):
      handleDrop(at: CGPoint(x: x, y: y))
    }
  }

  private func handleWatcherCreated(_ watcher: Watcher, session: any WatcherOverlaySession) {
    watchers.append(watcher)
    do {
      try persistence.save(watchers)
    } catch {
      NSLog("Failed to save watcher: %@", error.localizedDescription)
    }

    Task {
      await store.add(watcher)
      if watcher.armed {
        await WatcherArmService.arm(watcherID: watcher.id, bus: bus, store: store)
      }
      overlayController.register(watcherID: watcher.id, for: session)
      await refreshPopover()
    }
  }

  private func handleDeleteWatcher(id: WatcherID) {
    watchers.removeAll { $0.id == id }
    do {
      try persistence.save(watchers)
    } catch {
      NSLog("Failed to save after delete: %@", error.localizedDescription)
    }
    Task {
      await store.remove(id: id)
      overlayController.remove(watcherID: id)
      await refreshPopover()
    }
  }

  private func handleDrop(at appKitPoint: CGPoint) {
    popover.behavior = .transient
    popover.performClose(nil)

    // NSEvent.mouseLocation is AppKit bottom-left; CGWindowList bounds are CG top-left.
    let screenHeight = NSScreen.main?.frame.height ?? 0
    let cgPoint = CGPoint(x: appKitPoint.x, y: screenHeight - appKitPoint.y)

    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
      return
    }

    let ownPID = ProcessInfo.processInfo.processIdentifier
    var targetInfo: [String: Any]?
    for info in list {
      guard
        let pid = CGWindowDictParser.processIDValue(info[String(kCGWindowOwnerPID)]),
        pid != ownPID,
        // Skip untitled subwindows — they can't be matched by WindowResolver later.
        let windowTitle = info[String(kCGWindowName)] as? String, !windowTitle.isEmpty,
        let bounds = CGWindowDictParser.rectValue(info[String(kCGWindowBounds)]),
        bounds.contains(cgPoint)
      else { continue }
      targetInfo = info
      break
    }

    guard
      let info = targetInfo,
      let bounds = CGWindowDictParser.rectValue(info[String(kCGWindowBounds)]),
      let windowID = CGWindowDictParser.uint32Value(info[String(kCGWindowNumber)]),
      let pid = CGWindowDictParser.processIDValue(info[String(kCGWindowOwnerPID)])
    else {
      let alert = NSAlert()
      alert.messageText = "PixelWatch could not find a window at that location."
      alert.runModal()
      return
    }

    let title = (info[String(kCGWindowName)] as? String) ?? ""
    let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""

    let windowSnapshot = WindowSnapshot(
      windowID: windowID,
      processID: pid,
      bundleID: bundleID,
      title: title,
      bounds: bounds,
      isVisible: true
    )

    // Match the size of the floating drag panel exactly so the overlay lands where the
    // square was dropped. Clamp so the rect stays within the window bounds.
    let dropSize = CGSize(width: 120, height: 96)
    let unclamped = CGRect(
      x: cgPoint.x - dropSize.width / 2,
      y: cgPoint.y - dropSize.height / 2,
      width: dropSize.width,
      height: dropSize.height
    )
    let screenRect = CGRect(
      x: max(bounds.minX, min(unclamped.minX, bounds.maxX - dropSize.width)),
      y: max(bounds.minY, min(unclamped.minY, bounds.maxY - dropSize.height)),
      width: dropSize.width,
      height: dropSize.height
    )
    let draft = WatcherDraft(
      window: windowSnapshot,
      name: title.isEmpty ? bundleID : title,
      sensitivity: 0.5,
      command: "",
      armed: false
    )

    let session = FrozenOverlaySession(frozenRect: screenRect)
    let presenter = AppKitConfigureWatcherSheetPresenter()

    Task {
      guard let watcher = await presenter.present(draft: draft, overlay: session) else { return }
      handleWatcherCreatedFromDrag(watcher, windowID: windowID)
    }
  }

  private func handleWatcherCreatedFromDrag(_ watcher: Watcher, windowID: UInt32) {
    watchers.append(watcher)
    do {
      try persistence.save(watchers)
    } catch {
      NSLog("Failed to save watcher: %@", error.localizedDescription)
    }
    Task {
      await store.add(watcher)
      if watcher.armed {
        await WatcherArmService.arm(watcherID: watcher.id, bus: bus, store: store)
      }
      overlayController.restore(
        watcherID: watcher.id,
        windowID: windowID,
        windowRelativeRect: watcher.rect,
        state: watcher.armed ? .armed : .idle
      )
      await refreshPopover()
    }
  }

  private func startRuntime() {
    do {
      watchers = try persistence.load()
    } catch {
      NSLog("Failed to load watchers: %@", error.localizedDescription)
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
      await refreshPopover()
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
          if let state {
            overlayController.update(watcherID: watcherID, state: state)
          }
        }
        await refreshPopover()
      }
    }
  }

  private func refreshPopover() async {
    var items: [WatcherThumbnailItem] = []
    for watcher in watchers {
      let snap = await store.snapshot(for: watcher.id)
      items.append(WatcherThumbnailItem(
        id: watcher.id,
        name: watcher.name,
        state: snap?.state ?? .idle,
        latestFrame: snap?.latestFrame
      ))
    }
    popoverModel.items = items
  }

  private static var watchersURL: URL {
    FileManager.default
      .homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/PixelWatch/watchers.json")
  }
}
