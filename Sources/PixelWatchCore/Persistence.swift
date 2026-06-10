import Foundation

public struct WatcherPersistence: Sendable {
  public let url: URL

  public init(url: URL) {
    self.url = url
  }

  public func load() throws -> [Watcher] {
    guard FileManager.default.fileExists(atPath: url.path) else {
      return []
    }
    let data = try Data(contentsOf: url)
    return try Self.decoder.decode([Watcher].self, from: data)
  }

  public func save(_ watchers: [Watcher]) throws {
    let directory = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let data = try Self.encoder.encode(watchers)
    let temporaryURL = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
    try data.write(to: temporaryURL, options: .withoutOverwriting)

    if FileManager.default.fileExists(atPath: url.path) {
      _ = try FileManager.default.replaceItemAt(url, withItemAt: temporaryURL)
    } else {
      try FileManager.default.moveItem(at: temporaryURL, to: url)
    }
  }

  private static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
  }()

  private static let decoder = JSONDecoder()
}
