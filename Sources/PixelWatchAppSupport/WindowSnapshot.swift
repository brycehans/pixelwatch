import CoreGraphics
import Foundation

public struct WindowSnapshot: Equatable, Sendable {
  public let windowID: UInt32
  public let processID: pid_t
  public let bundleID: String
  public let title: String
  public let bounds: CGRect
  public let isVisible: Bool

  public init(
    windowID: UInt32,
    processID: pid_t,
    bundleID: String,
    title: String,
    bounds: CGRect,
    isVisible: Bool
  ) {
    self.windowID = windowID
    self.processID = processID
    self.bundleID = bundleID
    self.title = title
    self.bounds = bounds
    self.isVisible = isVisible
  }
}
