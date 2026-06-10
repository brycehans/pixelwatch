import AppKit
import QuartzCore

/// 800x400 borderless window: left half static mid-grey, right half hue-cycling at ~5 Hz.
/// Returns its CGWindowID once it's on-screen.
@MainActor
final class TestWindow {

  let window: NSWindow
  private let animatedLayer: CALayer
  private var displayLink: CVDisplayLink?
  private var startTime = CFAbsoluteTimeGetCurrent()

  init() {
    window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 800, height: 400),
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    window.title = "PixelWatch Bench"
    window.level = .floating
    window.isReleasedWhenClosed = false
    window.center()

    let root = CALayer()
    root.frame = CGRect(x: 0, y: 0, width: 800, height: 400)

    let staticHalf = CALayer()
    staticHalf.frame = CGRect(x: 0, y: 0, width: 400, height: 400)
    staticHalf.backgroundColor = CGColor(gray: 0.5, alpha: 1)
    root.addSublayer(staticHalf)

    animatedLayer = CALayer()
    animatedLayer.frame = CGRect(x: 400, y: 0, width: 400, height: 400)
    animatedLayer.backgroundColor = CGColor(red: 1, green: 0, blue: 0, alpha: 1)
    root.addSublayer(animatedLayer)

    let content = NSView(frame: root.frame)
    content.wantsLayer = true
    content.layer = root
    window.contentView = content
  }

  func show() {
    window.makeKeyAndOrderFront(nil)
    startDisplayLink()
  }

  func close() {
    stopDisplayLink()
    window.close()
  }

  /// Block until the window has a CGWindowID we can capture, up to `timeout` seconds.
  func waitForCGWindowID(timeout: TimeInterval = 2) -> CGWindowID? {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if let id = currentCGWindowID() { return id }
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    return nil
  }

  private func currentCGWindowID() -> CGWindowID? {
    let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
    guard let infos = raw as? [[String: Any]] else { return nil }
    let pid = ProcessInfo.processInfo.processIdentifier
    for info in infos {
      if let ownerPID = info[kCGWindowOwnerPID as String] as? Int32, ownerPID == pid,
         let name = info[kCGWindowName as String] as? String, name == "PixelWatch Bench",
         let id = info[kCGWindowNumber as String] as? CGWindowID {
        return id
      }
    }
    return nil
  }

  // MARK: animated half — hue cycle at ~5 Hz

  private func startDisplayLink() {
    var link: CVDisplayLink?
    CVDisplayLinkCreateWithActiveCGDisplays(&link)
    guard let link else { return }
    let pointer = Unmanaged.passUnretained(self).toOpaque()
    CVDisplayLinkSetOutputCallback(link, { _, _, _, _, _, ctx in
      // Re-derive `self` on the main actor from the Sendable opaque pointer
      // to keep Swift 6 strict concurrency happy (TestWindow is non-Sendable
      // and MainActor-isolated, so we can't capture `me` across the hop).
      guard let ctx else { return kCVReturnSuccess }
      DispatchQueue.main.async {
        let me = Unmanaged<TestWindow>.fromOpaque(ctx).takeUnretainedValue()
        MainActor.assumeIsolated { me.tick() }
      }
      return kCVReturnSuccess
    }, pointer)
    CVDisplayLinkStart(link)
    displayLink = link
  }

  private func stopDisplayLink() {
    if let link = displayLink { CVDisplayLinkStop(link) }
    displayLink = nil
  }

  private func tick() {
    let t = CFAbsoluteTimeGetCurrent() - startTime
    let hue = CGFloat((t * 5).truncatingRemainder(dividingBy: 1))   // 5 Hz cycle
    let color = NSColor(hue: hue, saturation: 1, brightness: 1, alpha: 1).cgColor
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    animatedLayer.backgroundColor = color
    CATransaction.commit()
  }
}
