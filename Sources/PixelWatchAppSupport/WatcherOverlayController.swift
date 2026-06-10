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
  /// Cancel the in-progress session, hide the overlay, and release tracking
  /// resources. After cancel(), the session is dead — don't call freeze()/frozenRect.
  func cancel()
  /// Suspend until the user freezes the overlay (clicks to pick a rect).
  /// Returns immediately if already frozen.
  func waitForFreeze() async
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
/// Internal (not private) so the controller's live convenience init can reference
/// the concrete type in its sessionDidStart hook.
@MainActor
final class DefaultWatcherOverlaySession: WatcherOverlaySession {
  private let overlay: WatcherOverlayWindow
  private let mouseLocationProvider: () -> CGPoint
  private(set) var currentFrame: CGRect
  private(set) var frozenRect: CGRect?

  private var trackingTimer: Timer?
  private var globalMonitor: Any?
  private var localMonitor: Any?
  private var freezeContinuation: CheckedContinuation<Void, Never>?

  init(overlay: WatcherOverlayWindow, initialFrame: CGRect, mouseLocationProvider: @escaping () -> CGPoint) {
    self.overlay = overlay
    self.currentFrame = initialFrame
    self.mouseLocationProvider = mouseLocationProvider
  }

  /// Start cursor-follow timer and click monitors. Called by the live path only.
  func startTracking() {
    trackingTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.tick() }
    }
    globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
      MainActor.assumeIsolated { self?.freeze() }
    }
    localMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
      MainActor.assumeIsolated { self?.freeze() }
      return event
    }
  }

  func freeze() {
    guard frozenRect == nil else { return }   // idempotent — multi-click safe
    frozenRect = currentFrame
    stopTracking()
    freezeContinuation?.resume()
    freezeContinuation = nil
  }

  func cancel() {
    stopTracking()
    overlay.setVisible(false)
    freezeContinuation?.resume()   // unblock any awaiter; callers should check frozenRect
    freezeContinuation = nil
  }

  func waitForFreeze() async {
    if frozenRect != nil { return }
    await withCheckedContinuation { continuation in
      freezeContinuation = continuation
    }
  }

  private func tick() {
    let mouse = mouseLocationProvider()
    let frame = CGRect(x: mouse.x - 100, y: mouse.y - 100, width: 100, height: 100)
    currentFrame = frame
    overlay.setFrame(frame)
  }

  private func stopTracking() {
    trackingTimer?.invalidate()
    trackingTimer = nil
    if let g = globalMonitor { NSEvent.removeMonitor(g); globalMonitor = nil }
    if let l = localMonitor { NSEvent.removeMonitor(l); localMonitor = nil }
  }
}

// MARK: - Coord conversion

/// Converts a top-left-origin rect (the controller's convention — top is `origin.y`)
/// to NSWindow's bottom-left-origin global screen coords. `screenHeight` is the
/// height of the screen the rect lives on.
///
/// The controller composes frames in TL terms ("cursor at the bottom-right of
/// the 100×100 square") because `tick()` math reads naturally that way; AppKit's
/// NSWindow.setFrame wants BL. This is the single point of conversion.
func screenBottomLeftRect(fromTopLeft frame: CGRect, screenHeight: CGFloat) -> CGRect {
  CGRect(
    x: frame.origin.x,
    y: screenHeight - frame.origin.y - frame.height,
    width: frame.width,
    height: frame.height
  )
}

// MARK: - Live NSPanel overlay

/// A borderless, floating NSPanel that implements WatcherOverlayWindow.
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
    // Frame comes in as top-left-origin; NSWindow wants bottom-left.
    let screenH = screen?.frame.height ?? NSScreen.main?.frame.height ?? 0
    let bl = screenBottomLeftRect(fromTopLeft: frame, screenHeight: screenH)
    setFrame(bl, display: true)
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
  /// Optional hook called after a session is created. The live path passes
  /// a closure that calls `startTracking()` on the concrete session to opt into
  /// cursor-follow + click monitors. Test paths omit this so no real NSEvent
  /// monitors are installed.
  private let sessionDidStart: @MainActor (any WatcherOverlaySession) -> Void
  /// Returns the PID of the currently-frontmost application, or nil if unknown.
  /// `sync()` hides any overlay whose target window's PID doesn't match this.
  private let frontmostProcessIDProvider: @MainActor () -> pid_t?

  private struct OverlayEntry {
    let session: DefaultWatcherOverlaySession
    let overlay: WatcherOverlayWindow
    var windowID: UInt32
    /// Overlay frame on screen when `register` was called (top-left origin).
    /// Used as the base of the delta translation in `sync()`.
    var anchorRect: CGRect?
    /// Window bounds at the moment `anchorRect` was captured. The delta
    /// between current bounds and these gives the translation to apply.
    var anchorBounds: CGRect?
  }

  private var entries: [WatcherID: OverlayEntry] = [:]

  // MARK: Init

  public init(
    overlayFactory: @escaping (WatcherID) -> WatcherOverlayWindow,
    mouseLocationProvider: @escaping () -> CGPoint,
    windowSnapshotProvider: some WindowSnapshotProviding,
    sessionDidStart: @escaping @MainActor (any WatcherOverlaySession) -> Void = { _ in },
    frontmostProcessIDProvider: @escaping @MainActor () -> pid_t? = {
      NSWorkspace.shared.frontmostApplication?.processIdentifier
    }
  ) {
    self.overlayFactory = overlayFactory
    self.mouseLocationProvider = mouseLocationProvider
    self.windowSnapshotProvider = windowSnapshotProvider
    self.sessionDidStart = sessionDidStart
    self.frontmostProcessIDProvider = frontmostProcessIDProvider
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
      windowSnapshotProvider: CGWindowSnapshotProvider(),
      sessionDidStart: { session in
        (session as? DefaultWatcherOverlaySession)?.startTracking()
      }
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
    let session = DefaultWatcherOverlaySession(
      overlay: overlay,
      initialFrame: initialFrame,
      mouseLocationProvider: mouseLocationProvider
    )

    overlay.setFrame(initialFrame)
    overlay.setVisible(true)
    overlay.setBorderColor(OverlayAppearance.borderColor(for: .idle))

    entries[sessionID] = OverlayEntry(session: session, overlay: overlay, windowID: windowID)

    sessionDidStart(session)

    return session
  }

  /// Re-key a previously-begun overlay session to its persisted watcher ID,
  /// so `update(watcherID:state:)` and `sync()` can find it. Call this once,
  /// after the user saves the configure sheet and the watcher is persisted.
  ///
  /// Captures the overlay's current frame and the target window's bounds so
  /// `sync()` can translate the overlay when the window moves.
  public func register(watcherID: WatcherID, for session: any WatcherOverlaySession) {
    // Identify by reference — the entry was inserted with the same session instance.
    guard let (currentKey, existing) = entries.first(where: { $0.value.session === session }) else {
      assertionFailure("WatcherOverlayController.register: session not found")
      return
    }
    var entry = existing
    entry.anchorRect = entry.session.frozenRect ?? entry.session.currentFrame
    entry.anchorBounds = windowSnapshotProvider.windowSnapshot(windowID: entry.windowID)?.bounds
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
  /// An overlay is visible only when its target window is on-screen AND the
  /// target's app is the frontmost app. Cmd+Tab away → hide; Cmd+Tab back → show.
  /// Registered overlays also follow their target window when it's dragged:
  /// the translation between the current bounds and `anchorBounds` is applied
  /// to `anchorRect` to produce the on-screen frame.
  public func sync() {
    let frontmostPID = frontmostProcessIDProvider()
    for (_, entry) in entries {
      guard let snapshot = windowSnapshotProvider.windowSnapshot(windowID: entry.windowID) else {
        entry.overlay.setVisible(false)
        continue
      }
      if let anchorRect = entry.anchorRect, let anchorBounds = entry.anchorBounds {
        let dx = snapshot.bounds.origin.x - anchorBounds.origin.x
        let dy = snapshot.bounds.origin.y - anchorBounds.origin.y
        entry.overlay.setFrame(anchorRect.offsetBy(dx: dx, dy: dy))
      }
      let isFrontmost = (snapshot.processID == frontmostPID)
      entry.overlay.setVisible(snapshot.isVisible && isFrontmost)
    }
  }
}

// MARK: - No-op fallback session

/// Returned by `begin(windowID:)` when the window cannot be resolved.
private final class NoOpWatcherOverlaySession: WatcherOverlaySession {
  private(set) var frozenRect: CGRect? = nil
  func freeze() {}
  func cancel() {}
  func waitForFreeze() async {}
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
