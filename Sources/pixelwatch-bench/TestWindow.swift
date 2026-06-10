import AppKit
import QuartzCore

/// 800x400 borderless window: left half static mid-grey, right half hue-cycling at ~5 Hz.
/// Returns its CGWindowID once it's on-screen.
@MainActor
final class TestWindow {

  let window: NSWindow
  private let animatedLayer: CALayer
  private var animationTimer: Timer?
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
    startAnimation()
  }

  func close() {
    stopAnimation()
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
  //
  // CVDisplayLink would be the precise approach, but the @convention(c)
  // callback runs on a non-main thread and Swift 6 strict concurrency
  // makes the hop back to MainActor.assumeIsolated unreliable (crashes
  // in the executor check). 5 Hz is well within Timer's resolution, so
  // a 0.05s Timer on the main run loop is a clean replacement.

  private func startAnimation() {
    animationTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.tick()
      }
    }
  }

  private func stopAnimation() {
    animationTimer?.invalidate()
    animationTimer = nil
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
