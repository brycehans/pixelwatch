import AppKit
import CoreGraphics
import Foundation

public protocol WindowCandidateProviding: Sendable {
  func candidates() -> [WindowCandidate]
}

public struct LiveWindowCandidateProvider: WindowCandidateProviding {
  public init() {}

  public func candidates() -> [WindowCandidate] {
    CGWindowCandidateProvider().candidates()
  }
}

public struct CGWindowCandidateProvider {
  private let windowInfoProvider: () -> [[String: Any]]
  private let bundleIdentifierForProcessID: (pid_t) -> String?

  public init() {
    self.init(
      windowInfo: {
        let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
        return CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
      },
      bundleIdentifierForProcessID: { processID in
        NSRunningApplication(processIdentifier: processID)?.bundleIdentifier
      }
    )
  }

  init(
    windowInfo: @escaping () -> [[String: Any]],
    bundleIdentifierForProcessID: @escaping (pid_t) -> String?
  ) {
    self.windowInfoProvider = windowInfo
    self.bundleIdentifierForProcessID = bundleIdentifierForProcessID
  }

  public func candidates() -> [WindowCandidate] {
    windowInfoProvider().compactMap { info in
      CGWindowCandidateParser.parse(
        info,
        bundleIdentifierForProcessID: bundleIdentifierForProcessID
      )
    }
  }
}

enum CGWindowCandidateParser {
  static func parse(
    _ info: [String: Any],
    bundleIdentifierForProcessID: (pid_t) -> String?
  ) -> WindowCandidate? {
    guard let windowID = uint32Value(info[String(kCGWindowNumber)]),
          let processID = processIDValue(info[String(kCGWindowOwnerPID)]),
          let title = info[String(kCGWindowName)] as? String,
          let bounds = rectValue(info[String(kCGWindowBounds)]),
          let bundleID = bundleIdentifierForProcessID(processID) else {
      return nil
    }

    return WindowCandidate(
      windowID: windowID,
      bundleID: bundleID,
      title: title,
      bounds: bounds
    )
  }

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
