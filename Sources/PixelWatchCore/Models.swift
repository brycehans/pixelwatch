import CoreGraphics
import Foundation

public typealias WatcherID = UUID

public struct Watcher: Codable, Equatable, Sendable {
  public let id: WatcherID
  public var name: String
  public var target: WindowBinding
  public var rect: CGRect
  public var sensitivity: Double
  public var tickIntervalSeconds: Double
  public var command: String
  public var armed: Bool

  public init(
    id: WatcherID,
    name: String,
    target: WindowBinding,
    rect: CGRect,
    sensitivity: Double,
    tickIntervalSeconds: Double,
    command: String,
    armed: Bool
  ) {
    self.id = id
    self.name = name
    self.target = target
    self.rect = rect
    self.sensitivity = sensitivity
    self.tickIntervalSeconds = tickIntervalSeconds
    self.command = command
    self.armed = armed
  }
}

public struct WindowBinding: Codable, Equatable, Sendable {
  public var bundleID: String
  public var titleMatch: TitleMatch
  public var windowIDHint: UInt32?
  public var lastKnownBounds: CGRect?

  public init(
    bundleID: String,
    titleMatch: TitleMatch,
    windowIDHint: UInt32? = nil,
    lastKnownBounds: CGRect? = nil
  ) {
    self.bundleID = bundleID
    self.titleMatch = titleMatch
    self.windowIDHint = windowIDHint
    self.lastKnownBounds = lastKnownBounds
  }
}

public enum TitleMatch: Codable, Equatable, Sendable {
  case exact(String)
  case contains(String)
  case regex(String)
}

public enum WatcherState: Codable, Equatable, Sendable {
  case idle
  case armed
  case triggered
  case errored(String)
}

public enum VanishReason: String, Codable, Equatable, Sendable {
  case windowClosed
  case appQuit
}

public enum FireReason: String, Codable, Equatable, Sendable {
  case pixelChange
  case windowVanished
  case appQuit
  case runHookNow
  case testHook
}

public enum PauseReason: String, Codable, Equatable, Sendable {
  case userPaused
}

public extension TitleMatch {
  var literalValue: String {
    switch self {
    case let .exact(value), let .contains(value), let .regex(value):
      value
    }
  }
}

public enum PixelWatchEvent: Equatable, Sendable {
  case armed(watcherID: WatcherID, baseline: PixelBuffer)
  case frameCaptured(watcherID: WatcherID, frame: PixelBuffer, at: Date)
  case diffComputed(watcherID: WatcherID, score: Double, frame: PixelBuffer)
  case thresholdExceeded(watcherID: WatcherID, score: Double, frame: PixelBuffer)
  case windowVanished(watcherID: WatcherID, reason: VanishReason)
  case hookStarted(watcherID: WatcherID, command: String, reason: FireReason)
  case hookFinished(watcherID: WatcherID, exit: Int32, stdout: String, stderr: String)
  case paused(watcherID: WatcherID, reason: PauseReason)
  case errored(watcherID: WatcherID, message: String)

  public var watcherID: WatcherID {
    switch self {
    case let .armed(watcherID, _),
         let .frameCaptured(watcherID, _, _),
         let .diffComputed(watcherID, _, _),
         let .thresholdExceeded(watcherID, _, _),
         let .windowVanished(watcherID, _),
         let .hookStarted(watcherID, _, _),
         let .hookFinished(watcherID, _, _, _),
         let .paused(watcherID, _),
         let .errored(watcherID, _):
      watcherID
    }
  }
}
