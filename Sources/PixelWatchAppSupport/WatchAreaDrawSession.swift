import AppKit
import CoreGraphics

public enum WatchAreaDrawFailure: Error, Equatable, Sendable {
  case cancelled
  case invalidWindow
  case invalidSelection
}

public struct WatchAreaDrawSelection: Equatable, Sendable {
  public let window: WindowSnapshot
  public let screenRect: CGRect

  public init(window: WindowSnapshot, screenRect: CGRect) {
    self.window = window
    self.screenRect = screenRect
  }
}

@MainActor
public final class WatchAreaDrawSession {
  public typealias DrawResult = Result<WatchAreaDrawSelection, WatchAreaDrawFailure>

  private let windowResolver: (CGPoint, CGFloat) -> WindowSnapshot?
  private let windowInfoProvider: () -> [[String: Any]]
  private let screenHeightProvider: () -> CGFloat
  private let ownProcessID: pid_t
  private let bundleIdentifierForProcessID: (pid_t) -> String?

  private var selectedWindow: WindowSnapshot?
  private var startPoint: CGPoint?
  private var overlayPanel: WatchAreaDrawPanel?
  private var continuation: CheckedContinuation<DrawResult, Never>?
  private var isFinished = false

  public convenience init() {
    self.init(
      windowInfoProvider: {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        return CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
      },
      screenHeightProvider: { NSScreen.main?.frame.height ?? 0 },
      ownProcessID: ProcessInfo.processInfo.processIdentifier,
      bundleIdentifierForProcessID: { processID in
        NSRunningApplication(processIdentifier: processID)?.bundleIdentifier
      }
    )
  }

  public init(
    windowResolver: ((CGPoint, CGFloat) -> WindowSnapshot?)? = nil,
    windowInfoProvider: @escaping () -> [[String: Any]],
    screenHeightProvider: @escaping () -> CGFloat,
    ownProcessID: pid_t,
    bundleIdentifierForProcessID: @escaping (pid_t) -> String? = { _ in nil }
  ) {
    self.windowInfoProvider = windowInfoProvider
    self.screenHeightProvider = screenHeightProvider
    self.ownProcessID = ownProcessID
    self.bundleIdentifierForProcessID = bundleIdentifierForProcessID
    if let windowResolver {
      self.windowResolver = windowResolver
    } else {
      self.windowResolver = { point, screenHeight in
        DropTargetResolver(
          ownProcessID: ownProcessID,
          bundleIdentifierForProcessID: bundleIdentifierForProcessID
        )
        .resolve(
          appKitDropPoint: point,
          screenHeight: screenHeight,
          windowInfo: windowInfoProvider()
        )
      }
    }
  }

  public func start() async -> DrawResult {
    installOverlay()
    installPanelHandlers()
    return await withCheckedContinuation { continuation in
      self.continuation = continuation
    }
  }

  public func prepareForProgrammaticInput() {
    installOverlay()
  }

  public func begin(atAppKitPoint appKitPoint: CGPoint) -> DrawResult? {
    let screenHeight = screenHeightProvider()
    guard let window = windowResolver(appKitPoint, screenHeight) else {
      return .failure(.invalidWindow)
    }

    let cgPoint = CGPoint(x: appKitPoint.x, y: screenHeight - appKitPoint.y)
    selectedWindow = window
    startPoint = cgPoint
    overlayPanel?.setTargetWindowBounds(window.bounds)
    overlayPanel?.setPreviewRect(.zero, label: "")
    return nil
  }

  public func updatePreview(atAppKitPoint appKitPoint: CGPoint) {
    guard let selectedWindow, let startPoint else { return }
    let screenHeight = screenHeightProvider()
    let cgPoint = CGPoint(x: appKitPoint.x, y: screenHeight - appKitPoint.y)
    let rect = DrawSelection.rect(from: startPoint, to: cgPoint, clampedTo: selectedWindow.bounds)
    overlayPanel?.setPreviewRect(rect, label: "\(Int(rect.width)) x \(Int(rect.height))")
  }

  public func updateAndFinish(atAppKitPoint appKitPoint: CGPoint) -> DrawResult {
    guard let selectedWindow, let startPoint else {
      return .failure(.invalidWindow)
    }

    let screenHeight = screenHeightProvider()
    let cgPoint = CGPoint(x: appKitPoint.x, y: screenHeight - appKitPoint.y)
    let rect = DrawSelection.rect(from: startPoint, to: cgPoint, clampedTo: selectedWindow.bounds)
    guard DrawSelection.isValid(rect) else {
      return .failure(.invalidSelection)
    }
    return .success(WatchAreaDrawSelection(window: selectedWindow, screenRect: rect))
  }

  public func cancel() -> DrawResult {
    .failure(.cancelled)
  }

  public func finishProgrammatic(atAppKitPoint appKitPoint: CGPoint) -> DrawResult {
    let result = updateAndFinish(atAppKitPoint: appKitPoint)
    tearDown()
    return result
  }

  public func cancelProgrammatic() -> DrawResult {
    tearDown()
    return .failure(.cancelled)
  }

  public func tearDownProgrammatic() {
    tearDown()
  }

  private func installOverlay() {
    guard overlayPanel == nil else { return }
    let screenFrame = NSScreen.main?.frame ?? .zero
    let panel = WatchAreaDrawPanel(
      contentRect: screenFrame,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 1)
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.orderFront(nil)
    overlayPanel = panel
  }

  private func installPanelHandlers() {
    overlayPanel?.onMouseDown = { [weak self] point in
      guard let self, !self.isFinished else { return }
      if let result = self.begin(atAppKitPoint: point) {
        self.finish(result)
      }
    }
    overlayPanel?.onMouseDragged = { [weak self] point in
      self?.updatePreview(atAppKitPoint: point)
    }
    overlayPanel?.onMouseUp = { [weak self] point in
      guard let self, !self.isFinished, self.startPoint != nil else { return }
      self.finish(self.updateAndFinish(atAppKitPoint: point))
    }
    overlayPanel?.onCancel = { [weak self] in
      self?.finish(DrawResult.failure(.cancelled))
    }
  }

  private func finish(_ result: DrawResult) {
    guard !isFinished else { return }
    isFinished = true
    tearDown()
    continuation?.resume(returning: result)
    continuation = nil
  }

  private func tearDown() {
    overlayPanel?.close()
    overlayPanel = nil
  }
}

@MainActor
private final class WatchAreaDrawPanel: NSPanel {
  private let drawView = WatchAreaDrawView(frame: .zero)
  var onMouseDown: @MainActor (CGPoint) -> Void = { _ in }
  var onMouseDragged: @MainActor (CGPoint) -> Void = { _ in }
  var onMouseUp: @MainActor (CGPoint) -> Void = { _ in }
  var onCancel: @MainActor () -> Void = {}

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }

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
    ignoresMouseEvents = false
    contentView = drawView
  }

  override func orderFront(_ sender: Any?) {
    super.orderFront(sender)
    makeKey()
  }

  override func mouseDown(with event: NSEvent) {
    onMouseDown(appKitScreenPoint(for: event))
  }

  override func mouseDragged(with event: NSEvent) {
    onMouseDragged(appKitScreenPoint(for: event))
  }

  override func mouseUp(with event: NSEvent) {
    onMouseUp(appKitScreenPoint(for: event))
  }

  override func keyDown(with event: NSEvent) {
    guard event.keyCode == 53 else {
      super.keyDown(with: event)
      return
    }
    onCancel()
  }

  func setTargetWindowBounds(_ bounds: CGRect) {
    drawView.targetWindowBounds = bounds
  }

  func setPreviewRect(_ rect: CGRect, label: String) {
    drawView.previewRect = rect
    drawView.previewLabel = label
  }

  private func appKitScreenPoint(for event: NSEvent) -> CGPoint {
    convertPoint(toScreen: event.locationInWindow)
  }
}

@MainActor
private final class WatchAreaDrawView: NSView {
  var targetWindowBounds: CGRect? {
    didSet { needsDisplay = true }
  }
  var previewRect: CGRect = .zero {
    didSet { needsDisplay = true }
  }
  var previewLabel: String = "" {
    didSet { needsDisplay = true }
  }

  override var isFlipped: Bool { true }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    guard let targetWindowBounds else { return }

    NSColor.black.withAlphaComponent(0.45).setFill()
    bounds.fill()

    NSGraphicsContext.current?.compositingOperation = .clear
    targetWindowBounds.fill()
    NSGraphicsContext.current?.compositingOperation = .sourceOver

    guard !previewRect.isEmpty else { return }
    NSColor.systemBlue.withAlphaComponent(0.10).setFill()
    previewRect.fill()

    let path = NSBezierPath(rect: previewRect)
    NSColor.systemBlue.setStroke()
    path.lineWidth = 3
    path.stroke()

    guard !previewLabel.isEmpty else { return }
    let labelRect = CGRect(
      x: previewRect.minX,
      y: max(0, previewRect.minY - 18),
      width: max(72, previewRect.width),
      height: 18
    )
    NSColor.black.withAlphaComponent(0.68).setFill()
    labelRect.fill()
    let attrs: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 10, weight: .medium),
      .foregroundColor: NSColor.white,
    ]
    let text = NSAttributedString(string: previewLabel, attributes: attrs)
    let size = text.size()
    text.draw(
      at: CGPoint(
        x: labelRect.midX - size.width / 2,
        y: labelRect.midY - size.height / 2
      )
    )
  }
}
