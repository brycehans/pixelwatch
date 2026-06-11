import CoreGraphics
import Foundation
import PixelWatchCore

public struct DropTargetResolver {
  private let ownProcessID: pid_t
  private let bundleIdentifierForProcessID: (pid_t) -> String?

  public init(
    ownProcessID: pid_t,
    bundleIdentifierForProcessID: @escaping (pid_t) -> String?
  ) {
    self.ownProcessID = ownProcessID
    self.bundleIdentifierForProcessID = bundleIdentifierForProcessID
  }

  public func resolve(
    appKitDropPoint: CGPoint,
    screenHeight: CGFloat,
    windowInfo: [[String: Any]]
  ) -> WindowSnapshot? {
    let cgPoint = CGPoint(x: appKitDropPoint.x, y: screenHeight - appKitDropPoint.y)

    for info in windowInfo {
      let layer = CGWindowDictParser.intValue(info[String(kCGWindowLayer)]) ?? 0
      guard layer == 0 else { continue }

      guard let pid = CGWindowDictParser.processIDValue(info[String(kCGWindowOwnerPID)]),
            pid != ownProcessID,
            let bounds = CGWindowDictParser.rectValue(info[String(kCGWindowBounds)]),
            bounds.contains(cgPoint),
            let windowID = CGWindowDictParser.uint32Value(info[String(kCGWindowNumber)]) else {
        continue
      }

      return WindowSnapshot(
        windowID: windowID,
        processID: pid,
        bundleID: bundleIdentifierForProcessID(pid) ?? "",
        title: (info[String(kCGWindowName)] as? String) ?? "",
        bounds: bounds,
        isVisible: true
      )
    }

    return nil
  }
}
