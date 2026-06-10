import AppKit
import CoreGraphics
import Foundation

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
      guard let ownerPID = Self.processIDValue(info[String(kCGWindowOwnerPID)]),
            ownerPID == frontmost.pid else {
        continue
      }

      let layer = Self.intValue(info[String(kCGWindowLayer)]) ?? 0
      guard layer == 0 else { continue }

      let isOnscreen = Self.boolValue(info[String(kCGWindowIsOnscreen)]) ?? true
      guard isOnscreen else { continue }

      guard let windowID = Self.uint32Value(info[String(kCGWindowNumber)]),
            let bounds = Self.rectValue(info[String(kCGWindowBounds)]) else {
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

  // MARK: - Numeric coercion helpers
  //
  // Mirrors PixelWatchCore.CGWindowCandidateProvider — copied privately to keep
  // PixelWatchAppSupport's surface area small. `CGWindowListCopyWindowInfo`
  // returns `NSNumber`, but tests pass raw `Int`/`Bool`, so we accept both.

  private static func uint32Value(_ value: Any?) -> UInt32? {
    switch value {
    case let value as UInt32:
      value
    case let value as UInt64 where value <= UInt64(UInt32.max):
      UInt32(value)
    case let value as Int where value >= 0 && value <= Int(UInt32.max):
      UInt32(value)
    case let value as NSNumber where value.uint64Value <= UInt64(UInt32.max):
      value.uint32Value
    default:
      nil
    }
  }

  private static func processIDValue(_ value: Any?) -> pid_t? {
    switch value {
    case let value as pid_t:
      value
    case let value as Int where value >= 0 && value <= Int(Int32.max):
      pid_t(value)
    case let value as NSNumber where value.int64Value >= 0 && value.int64Value <= Int64(Int32.max):
      pid_t(value.int32Value)
    default:
      nil
    }
  }

  private static func intValue(_ value: Any?) -> Int? {
    switch value {
    case let value as Int:
      value
    case let value as NSNumber:
      value.intValue
    default:
      nil
    }
  }

  private static func boolValue(_ value: Any?) -> Bool? {
    switch value {
    case let value as Bool:
      value
    case let value as NSNumber:
      value.boolValue
    default:
      nil
    }
  }

  private static func rectValue(_ value: Any?) -> CGRect? {
    guard let dictionary = value as? [String: Any],
          let x = cgFloatValue(dictionary["X"]),
          let y = cgFloatValue(dictionary["Y"]),
          let width = cgFloatValue(dictionary["Width"]),
          let height = cgFloatValue(dictionary["Height"]) else {
      return nil
    }

    return CGRect(x: x, y: y, width: width, height: height)
  }

  private static func cgFloatValue(_ value: Any?) -> CGFloat? {
    switch value {
    case let value as CGFloat:
      value
    case let value as Double:
      CGFloat(value)
    case let value as Float:
      CGFloat(value)
    case let value as Int:
      CGFloat(value)
    case let value as NSNumber:
      CGFloat(value.doubleValue)
    default:
      nil
    }
  }
}
