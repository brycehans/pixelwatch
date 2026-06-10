import AppKit
import Foundation
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

  func applicationDidFinishLaunching(_: Notification) {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    statusItem?.button?.title = "PixelWatch"
    startRuntime()
    refreshMenu()
  }

  func applicationWillTerminate(_: Notification) {
    stageTasks.forEach { $0.cancel() }
    eventTask?.cancel()
  }

  private func startRuntime() {
    do {
      watchers = try persistence.load()
    } catch {
      lastEventDescription = "Failed to load watchers: \(error)"
      watchers = []
    }

    Task {
      for watcher in watchers {
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

      for watcher in watchers where watcher.armed {
        await WatcherArmService.arm(watcherID: watcher.id, bus: bus, store: store)
      }
      await MainActor.run { refreshMenu() }
    }
  }

  private func startEventMonitor() {
    eventTask = Task {
      var events = await bus.subscribe().makeAsyncIterator()
      while !Task.isCancelled, let event = await events.next() {
        await MainActor.run {
          lastEventDescription = Self.describe(event)
          refreshMenu()
        }
      }
    }
  }

  private func refreshMenu() {
    let menu = NSMenu()
    let title = NSMenuItem(title: "PixelWatch", action: nil, keyEquivalent: "")
    title.isEnabled = false
    menu.addItem(title)
    menu.addItem(NSMenuItem(title: "\(watchers.count) watcher\(watchers.count == 1 ? "" : "s") loaded", action: nil, keyEquivalent: ""))
    menu.addItem(NSMenuItem(title: lastEventDescription, action: nil, keyEquivalent: ""))
    menu.addItem(.separator())
    menu.addItem(NSMenuItem(title: "Quit PixelWatch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
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
