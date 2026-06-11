import CoreGraphics
import Foundation

public typealias WatcherID = UUID

public enum CommandMode: Codable, Equatable, Sendable {
  case shell(command: String)
  case notification(body: String)

  public var displayString: String {
    switch self {
    case .shell(let cmd): return cmd
    case .notification(let body): return "[notification] \(body)"
    }
  }
}

public struct Watcher: Equatable, Sendable {
  public let id: WatcherID
  public var target: WindowBinding
  public var rect: CGRect
  public var sensitivity: Double
  public var tickIntervalSeconds: Double
  public var commandMode: CommandMode
  public var armed: Bool

  public init(
    id: WatcherID,
    target: WindowBinding,
    rect: CGRect,
    sensitivity: Double,
    tickIntervalSeconds: Double,
    commandMode: CommandMode,
    armed: Bool
  ) {
    self.id = id
    self.target = target
    self.rect = rect
    self.sensitivity = sensitivity
    self.tickIntervalSeconds = tickIntervalSeconds
    self.commandMode = commandMode
    self.armed = armed
  }

  private enum CodingKeys: String, CodingKey {
    case id, target, rect, sensitivity, tickIntervalSeconds, armed
    case commandMode
    case command // legacy key — decode only
  }
}

extension Watcher: Codable {
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(WatcherID.self, forKey: .id)
    target = try c.decode(WindowBinding.self, forKey: .target)
    rect = try c.decode(CGRect.self, forKey: .rect)
    sensitivity = try c.decode(Double.self, forKey: .sensitivity)
    tickIntervalSeconds = try c.decode(Double.self, forKey: .tickIntervalSeconds)
    armed = try c.decode(Bool.self, forKey: .armed)
    if let mode = try c.decodeIfPresent(CommandMode.self, forKey: .commandMode) {
      commandMode = mode
    } else {
      let cmd = (try c.decodeIfPresent(String.self, forKey: .command)) ?? ""
      commandMode = .shell(command: cmd)
    }
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(id, forKey: .id)
    try c.encode(target, forKey: .target)
    try c.encode(rect, forKey: .rect)
    try c.encode(sensitivity, forKey: .sensitivity)
    try c.encode(tickIntervalSeconds, forKey: .tickIntervalSeconds)
    try c.encode(armed, forKey: .armed)
    try c.encode(commandMode, forKey: .commandMode)
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
  case popoverShowRequested
  case popoverHideRequested

  public var targetWatcherID: WatcherID? {
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
      return watcherID
    case .popoverShowRequested, .popoverHideRequested:
      return nil
    }
  }

  public var watcherID: WatcherID {
    guard let watcherID = targetWatcherID else {
      preconditionFailure("PixelWatchEvent \(self) is not watcher-scoped")
    }
    return watcherID
  }
}
