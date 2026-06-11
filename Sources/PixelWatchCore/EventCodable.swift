import Foundation

// MARK: - PixelBuffer Codable

extension PixelBuffer: Codable {
  enum CodingKeys: String, CodingKey { case width, height, linearRGB }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let width = try c.decode(Int.self, forKey: .width)
    let height = try c.decode(Int.self, forKey: .height)
    let base64 = try c.decode(String.self, forKey: .linearRGB)
    guard let data = Data(base64Encoded: base64) else {
      throw DecodingError.dataCorruptedError(
        forKey: .linearRGB,
        in: c,
        debugDescription: "linearRGB is not valid base64"
      )
    }
    let count = data.count / MemoryLayout<Float>.size
    var floats = [Float](repeating: 0, count: count)
    _ = floats.withUnsafeMutableBytes { data.copyBytes(to: $0) }
    self.init(width: width, height: height, linearRGB: floats)
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(width, forKey: .width)
    try c.encode(height, forKey: .height)
    let data = linearRGB.withUnsafeBufferPointer { Data(buffer: $0) }
    try c.encode(data.base64EncodedString(), forKey: .linearRGB)
  }
}

// MARK: - PixelWatchEvent Codable

extension PixelWatchEvent: Codable {
  // All fields that appear in any case.
  private enum CodingKeys: String, CodingKey {
    case type
    case watcherID
    case baseline
    case frame
    case at
    case score
    case reason
    case command
    case exit
    case stdout
    case stderr
    case message
  }

  // "type" discriminator values match the case names (camelCase).
  private enum EventType: String, Codable {
    case armed
    case frameCaptured
    case diffComputed
    case thresholdExceeded
    case windowVanished
    case hookStarted
    case hookFinished
    case paused
    case errored
    case popoverShowRequested
    case popoverHideRequested
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let type = try c.decode(EventType.self, forKey: .type)

    switch type {
    case .armed:
      let watcherID = try c.decode(WatcherID.self, forKey: .watcherID)
      let baseline = try c.decode(PixelBuffer.self, forKey: .baseline)
      self = .armed(watcherID: watcherID, baseline: baseline)

    case .frameCaptured:
      let watcherID = try c.decode(WatcherID.self, forKey: .watcherID)
      let frame = try c.decode(PixelBuffer.self, forKey: .frame)
      let epochSeconds = try c.decode(Double.self, forKey: .at)
      let at = Date(timeIntervalSince1970: epochSeconds)
      self = .frameCaptured(watcherID: watcherID, frame: frame, at: at)

    case .diffComputed:
      let watcherID = try c.decode(WatcherID.self, forKey: .watcherID)
      let score = try c.decode(Double.self, forKey: .score)
      let frame = try c.decode(PixelBuffer.self, forKey: .frame)
      self = .diffComputed(watcherID: watcherID, score: score, frame: frame)

    case .thresholdExceeded:
      let watcherID = try c.decode(WatcherID.self, forKey: .watcherID)
      let score = try c.decode(Double.self, forKey: .score)
      let frame = try c.decode(PixelBuffer.self, forKey: .frame)
      self = .thresholdExceeded(watcherID: watcherID, score: score, frame: frame)

    case .windowVanished:
      let watcherID = try c.decode(WatcherID.self, forKey: .watcherID)
      let reason = try c.decode(VanishReason.self, forKey: .reason)
      self = .windowVanished(watcherID: watcherID, reason: reason)

    case .hookStarted:
      let watcherID = try c.decode(WatcherID.self, forKey: .watcherID)
      let command = try c.decode(String.self, forKey: .command)
      let reason = try c.decode(FireReason.self, forKey: .reason)
      self = .hookStarted(watcherID: watcherID, command: command, reason: reason)

    case .hookFinished:
      let watcherID = try c.decode(WatcherID.self, forKey: .watcherID)
      let exitCode = try c.decode(Int32.self, forKey: .exit)
      let stdout = try c.decode(String.self, forKey: .stdout)
      let stderr = try c.decode(String.self, forKey: .stderr)
      self = .hookFinished(watcherID: watcherID, exit: exitCode, stdout: stdout, stderr: stderr)

    case .paused:
      let watcherID = try c.decode(WatcherID.self, forKey: .watcherID)
      let reason = try c.decode(PauseReason.self, forKey: .reason)
      self = .paused(watcherID: watcherID, reason: reason)

    case .errored:
      let watcherID = try c.decode(WatcherID.self, forKey: .watcherID)
      let message = try c.decode(String.self, forKey: .message)
      self = .errored(watcherID: watcherID, message: message)

    case .popoverShowRequested:
      self = .popoverShowRequested

    case .popoverHideRequested:
      self = .popoverHideRequested
    }
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)

    switch self {
    case let .armed(watcherID, baseline):
      try c.encode(EventType.armed, forKey: .type)
      try c.encode(watcherID, forKey: .watcherID)
      try c.encode(baseline, forKey: .baseline)

    case let .frameCaptured(watcherID, frame, at):
      try c.encode(EventType.frameCaptured, forKey: .type)
      try c.encode(watcherID, forKey: .watcherID)
      try c.encode(frame, forKey: .frame)
      try c.encode(at.timeIntervalSince1970, forKey: .at)

    case let .diffComputed(watcherID, score, frame):
      try c.encode(EventType.diffComputed, forKey: .type)
      try c.encode(watcherID, forKey: .watcherID)
      try c.encode(score, forKey: .score)
      try c.encode(frame, forKey: .frame)

    case let .thresholdExceeded(watcherID, score, frame):
      try c.encode(EventType.thresholdExceeded, forKey: .type)
      try c.encode(watcherID, forKey: .watcherID)
      try c.encode(score, forKey: .score)
      try c.encode(frame, forKey: .frame)

    case let .windowVanished(watcherID, reason):
      try c.encode(EventType.windowVanished, forKey: .type)
      try c.encode(watcherID, forKey: .watcherID)
      try c.encode(reason, forKey: .reason)

    case let .hookStarted(watcherID, command, reason):
      try c.encode(EventType.hookStarted, forKey: .type)
      try c.encode(watcherID, forKey: .watcherID)
      try c.encode(command, forKey: .command)
      try c.encode(reason, forKey: .reason)

    case let .hookFinished(watcherID, exitCode, stdout, stderr):
      try c.encode(EventType.hookFinished, forKey: .type)
      try c.encode(watcherID, forKey: .watcherID)
      try c.encode(exitCode, forKey: .exit)
      try c.encode(stdout, forKey: .stdout)
      try c.encode(stderr, forKey: .stderr)

    case let .paused(watcherID, reason):
      try c.encode(EventType.paused, forKey: .type)
      try c.encode(watcherID, forKey: .watcherID)
      try c.encode(reason, forKey: .reason)

    case let .errored(watcherID, message):
      try c.encode(EventType.errored, forKey: .type)
      try c.encode(watcherID, forKey: .watcherID)
      try c.encode(message, forKey: .message)

    case .popoverShowRequested:
      try c.encode(EventType.popoverShowRequested, forKey: .type)

    case .popoverHideRequested:
      try c.encode(EventType.popoverHideRequested, forKey: .type)
    }
  }
}
