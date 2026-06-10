import AppKit
import CoreGraphics
import Foundation
import PixelWatchCore

public protocol FocusedWindowProviding: Sendable {
  func focusedWindow() -> WindowSnapshot?
}

public struct FrontmostApp: Sendable {
  public let pid: pid_t

  public init(pid: pid_t) {
    self.pid = pid
  }
}

public struct CGFocusedWindowProvider: FocusedWindowProviding {
  private let frontmostApplication: @Sendable () -> FrontmostApp?
  private let windowInfoProvider: @Sendable () -> [[String: Any]]
  private let bundleIdentifierForProcessID: @Sendable (pid_t) -> String?

  public init() {
    self.init(
      frontmostApplication: {
        NSWorkspace.shared.frontmostApplication.map { FrontmostApp(pid: $0.processIdentifier) }
      },
      windowInfoProvider: {
        let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
        return CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
      },
      bundleIdentifierForProcessID: { processID in
        NSRunningApplication(processIdentifier: processID)?.bundleIdentifier
      }
    )
  }

  public init(
    frontmostApplication: @escaping @Sendable () -> FrontmostApp?,
    windowInfoProvider: @escaping @Sendable () -> [[String: Any]],
    bundleIdentifierForProcessID: @escaping @Sendable (pid_t) -> String? = { _ in nil }
  ) {
    self.frontmostApplication = frontmostApplication
    self.windowInfoProvider = windowInfoProvider
    self.bundleIdentifierForProcessID = bundleIdentifierForProcessID
  }

  public func focusedWindow() -> WindowSnapshot? {
    guard let frontmost = frontmostApplication() else { return nil }

    let windows = windowInfoProvider()
    for info in windows {
      guard let ownerPID = CGWindowDictParser.processIDValue(info[String(kCGWindowOwnerPID)]),
            ownerPID == frontmost.pid else {
        continue
      }

      let layer = CGWindowDictParser.intValue(info[String(kCGWindowLayer)]) ?? 0
      guard layer == 0 else { continue }

      // CGWindowListCopyWindowInfo omits kCGWindowIsOnscreen for off-screen
      // windows, so missing must mean "not visible" — skip.
      let isOnscreen = CGWindowDictParser.boolValue(info[String(kCGWindowIsOnscreen)]) ?? false
      guard isOnscreen else { continue }

      guard let windowID = CGWindowDictParser.uint32Value(info[String(kCGWindowNumber)]),
            let bounds = CGWindowDictParser.rectValue(info[String(kCGWindowBounds)]) else {
        continue
      }

      let title = (info[String(kCGWindowName)] as? String) ?? ""
      let bundleID = bundleIdentifierForProcessID(ownerPID) ?? ""

      return WindowSnapshot(
        windowID: windowID,
        processID: ownerPID,
        bundleID: bundleID,
        title: title,
        bounds: bounds,
        isVisible: isOnscreen
      )
    }

    return nil
  }
}
