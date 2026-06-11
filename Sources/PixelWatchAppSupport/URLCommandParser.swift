import Foundation
import PixelWatchCore

public enum URLCommand: Equatable, Sendable {
  case arm(id: WatcherID)
  case pause(id: WatcherID)
  case delete(id: WatcherID)
}

public enum URLCommandParser {
  public static func parse(_ url: URL) -> URLCommand? {
    guard
      let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      let action = components.host,
      let idString = components.queryItems?.first(where: { $0.name == "id" })?.value,
      let id = UUID(uuidString: idString)
    else { return nil }

    switch action {
    case "arm": return .arm(id: id)
    case "pause": return .pause(id: id)
    case "delete": return .delete(id: id)
    default: return nil
    }
  }
}
