import CoreGraphics
import Foundation

public struct WindowCandidate: Equatable, Sendable {
  public let windowID: UInt32
  public let bundleID: String
  public let title: String
  public let bounds: CGRect

  public init(windowID: UInt32, bundleID: String, title: String, bounds: CGRect) {
    self.windowID = windowID
    self.bundleID = bundleID
    self.title = title
    self.bounds = bounds
  }
}

public enum WindowResolver {
  public static func resolve(
    binding: WindowBinding,
    candidates: [WindowCandidate]
  ) -> WindowCandidate? {
    if let hint = binding.windowIDHint,
       let candidate = candidates.first(where: { $0.windowID == hint }) {
      return candidate
    }

    let matches = candidates.filter { candidate in
      candidate.bundleID == binding.bundleID && binding.titleMatch.matches(candidate.title)
    }

    guard let lastKnownBounds = binding.lastKnownBounds else {
      return matches.first
    }

    return matches.max { lhs, rhs in
      lhs.bounds.intersection(lastKnownBounds).area < rhs.bounds.intersection(lastKnownBounds).area
    }
  }
}

private extension TitleMatch {
  func matches(_ title: String) -> Bool {
    switch self {
    case let .exact(value):
      title == value
    case let .contains(value):
      title.contains(value)
    case let .regex(pattern):
      title.range(of: pattern, options: .regularExpression) != nil
    }
  }
}

private extension CGRect {
  var area: CGFloat {
    guard !isNull, !isEmpty else { return 0 }
    return width * height
  }
}
