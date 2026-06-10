import AppKit
import CoreGraphics

// MARK: - Protocols

/// A lightweight handle to an in-progress overlay-placement session.
///
/// Main-actor isolated because the session backs an AppKit overlay window and
/// is registered with the @MainActor `WatcherOverlayController`. `AnyObject`
/// so the controller can identify the session by reference in `register`.
@MainActor
public protocol WatcherOverlaySession: AnyObject {
  /// The rect chosen by the user after calling `freeze()`. Nil until frozen.
  var frozenRect: CGRect? { get }
  /// Lock the overlay at its current position and record `frozenRect`.
  func freeze()
}

/// An overlay window that the controller drives.
///
/// Not Sendable — AppKit objects must remain on the main thread. The controller
/// is @MainActor-isolated and drives overlay windows only from there.
public protocol WatcherOverlayWindow: AnyObject {
  func setFrame(_ frame: CGRect)
  func setBorderColor(_ color: NSColor)
  func setVisible(_ visible: Bool)
}

/// Provides live window geometry by window ID. Sendable so the controller can
/// hold it across concurrency boundaries.
public protocol WindowSnapshotProviding: Sendable {
  func windowSnapshot(windowID: UInt32) -> WindowSnapshot?
}

// MARK: - Session implementation

/// Backs a WatcherOverlaySession. Lives on the main actor with the controller.
private final class DefaultWatcherOverlaySession: WatcherOverlaySession {
  private let overlay: WatcherOverlayWindow
  // NOTE: currentFrame is updated by cursor-tracking — not wired in this task.
  // The live NSPanel overlay will mutate this via its mouse-move handler.
  private var currentFrame: CGRect
  private(set) var frozenRect: CGRect?

  init(overlay: WatcherOverlayWindow, initialFrame: CGRect) {
    self.overlay = overlay
    self.currentFrame = initialFrame
  }

  func freeze() {
    frozenRect = currentFrame
  }
}

// MARK: - Live NSPanel overlay

/// A borderless, floating NSPanel that implements WatcherOverlayWindow.
/// Cursor-follow polling and click-to-freeze are wired by the AppKit shell
/// via sync() — not implemented in this task.
private final class WatcherOverlayPanel: NSPanel, @preconcurrency WatcherOverlayWindow {
  override init(
    contentRect: NSRect,
    styleMask style: NSWindow.StyleMask,
    backing backingStoreType: NSWindow.BackingStoreType,
    defer flag: Bool
  ) {
    super.init(
      contentRect: contentRect,
      styleMask: style,
      backing: backingStoreType,
      defer: flag
    )
    isOpaque = false
    backgroundColor = .clear
    hasShadow = false
    isMovable = false
    level = .floating
    ignoresMouseEvents = false
    contentView?.wantsLayer = true
    contentView?.layer?.borderWidth = 3
    contentView?.layer?.cornerRadius = 0
  }

  func setFrame(_ frame: CGRect) {
    setFrame(frame, display: true)
  }

  func setBorderColor(_ color: NSColor) {
    contentView?.layer?.borderColor = color.cgColor
  }

  func setVisible(_ visible: Bool) {
    if visible {
      orderFront(nil)
    } else {
      orderOut(nil)
    }
  }
}

// MARK: - Controller

/// Manages overlay windows for in-flight and active watchers.
///
/// Lifecycle:
/// 1. Call `begin(windowID:)` when the user triggers "new watcher" — the controller
///    creates a 100×100 overlay anchored below-left of the cursor and returns a session.
/// 2. The caller (or the live overlay's mouse-tracking) calls `session.freeze()` to
///    lock in the rect.
/// 3. Call `update(watcherID:state:)` whenever watcher state changes to repaint the
///    border color.
/// 4. Call `sync()` periodically to refresh overlay position/visibility against the
///    live window geometry.
@MainActor
public final class WatcherOverlayController {
  private let overlayFactory: (WatcherID) -> WatcherOverlayWindow
  private let mouseLocationProvider: () -> CGPoint
  private let windowSnapshotProvider: any WindowSnapshotProviding

  private struct OverlayEntry {
    let session: DefaultWatcherOverlaySession
    let overlay: WatcherOverlayWindow
    var windowID: UInt32
  }

  private var entries: [WatcherID: OverlayEntry] = [:]

  // MARK: Init

  public init(
    overlayFactory: @escaping (WatcherID) -> WatcherOverlayWindow,
    mouseLocationProvider: @escaping () -> CGPoint,
    windowSnapshotProvider: some WindowSnapshotProviding
  ) {
    self.overlayFactory = overlayFactory
    self.mouseLocationProvider = mouseLocationProvider
    self.windowSnapshotProvider = windowSnapshotProvider
  }

  /// Convenience init that wires up live AppKit dependencies.
  public convenience init() {
    self.init(
      overlayFactory: { _ in
        // The controller is @MainActor; this closure is only called from begin()
        // which is @MainActor. assumeIsolated keeps Swift 6 happy because the
        // closure type itself is nonisolated.
        MainActor.assumeIsolated {
          WatcherOverlayPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
          )
        }
      },
      mouseLocationProvider: {
        // NSEvent.mouseLocation is bottom-left origin; flip to top-left.
        let e = NSEvent.mouseLocation
        let screenHeight = NSScreen.main?.frame.height ?? 0
        return CGPoint(x: e.x, y: screenHeight - e.y)
      },
      windowSnapshotProvider: CGWindowSnapshotProvider()
    )
  }

  // MARK: Public API

  /// Begin a new overlay session anchored to the given window.
  /// Returns a no-op session if the window cannot be resolved.
  @discardableResult
  public func begin(windowID: UInt32) -> any WatcherOverlaySession {
    guard windowSnapshotProvider.windowSnapshot(windowID: windowID) != nil else {
      assertionFailure("WatcherOverlayController.begin: no snapshot for windowID \(windowID)")
      return NoOpWatcherOverlaySession()
    }

    let mouse = mouseLocationProvider()
    // Position: the overlay's top-left is at (mouse.x - 100, mouse.y - 100),
    // placing the cursor at the bottom-right corner of the 100×100 square.
    let initialFrame = CGRect(
      x: mouse.x - 100,
      y: mouse.y - 100,
      width: 100,
      height: 100
    )

    let sessionID = WatcherID()
    let overlay = overlayFactory(sessionID)
    let session = DefaultWatcherOverlaySession(overlay: overlay, initialFrame: initialFrame)

    overlay.setFrame(initialFrame)
    overlay.setVisible(true)
    overlay.setBorderColor(OverlayAppearance.borderColor(for: .idle))

    entries[sessionID] = OverlayEntry(session: session, overlay: overlay, windowID: windowID)

    return session
  }

  /// Re-key a previously-begun overlay session to its persisted watcher ID,
  /// so `update(watcherID:state:)` and `sync()` can find it. Call this once,
  /// after the user saves the configure sheet and the watcher is persisted.
  public func register(watcherID: WatcherID, for session: any WatcherOverlaySession) {
    // Identify by reference — the entry was inserted with the same session instance.
    guard let (currentKey, entry) = entries.first(where: { $0.value.session === session }) else {
      assertionFailure("WatcherOverlayController.register: session not found")
      return
    }
    entries.removeValue(forKey: currentKey)
    entries[watcherID] = entry
  }

  /// Update the border color for an active watcher's overlay.
  public func update(watcherID: WatcherID, state: WatcherState) {
    guard let entry = entries[watcherID] else { return }
    entry.overlay.setBorderColor(OverlayAppearance.borderColor(for: state))
    entry.overlay.setVisible(true)
  }

  /// Refresh overlay position and visibility against current window geometry.
  /// TODO: live polling is wired by the live NSPanel — sync() is the public hook
  /// for the AppKit shell to drive per-display-link tick or timer tick.
  public func sync() {
    for (_, entry) in entries {
      guard let snapshot = windowSnapshotProvider.windowSnapshot(windowID: entry.windowID) else {
        entry.overlay.setVisible(false)
        continue
      }
      entry.overlay.setVisible(snapshot.isVisible)
    }
  }
}

// MARK: - No-op fallback session

/// Returned by `begin(windowID:)` when the window cannot be resolved.
private final class NoOpWatcherOverlaySession: WatcherOverlaySession {
  private(set) var frozenRect: CGRect? = nil
  func freeze() {}
}

// MARK: - Live WindowSnapshotProviding

/// Uses CGWindowListCopyWindowInfo to resolve a window by ID.
private struct CGWindowSnapshotProvider: WindowSnapshotProviding {
  func windowSnapshot(windowID: UInt32) -> WindowSnapshot? {
    let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
    guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
      return nil
    }
    for info in list {
      guard let id = CGWindowDictParser.uint32Value(info[String(kCGWindowNumber)]),
            id == windowID else { continue }

      guard let bounds = CGWindowDictParser.rectValue(info[String(kCGWindowBounds)]) else { continue }
      let pid = CGWindowDictParser.processIDValue(info[String(kCGWindowOwnerPID)]) ?? 0
      let title = (info[String(kCGWindowName)] as? String) ?? ""
      let isOnscreen = CGWindowDictParser.boolValue(info[String(kCGWindowIsOnscreen)]) ?? false

      return WindowSnapshot(
        windowID: id,
        processID: pid,
        bundleID: "",
        title: title,
        bounds: bounds,
        isVisible: isOnscreen
      )
    }
    return nil
  }
}
