import CoreGraphics
import XCTest
@testable import PixelWatchCore

final class PersistenceTests: XCTestCase {
  func testSaveAndLoadRoundTripsWatchers() throws {
    let directory = try makeTemporaryDirectory()
    let url = directory.appendingPathComponent("watchers.json")
    let persistence = WatcherPersistence(url: url)
    let watchers = [
      Watcher(
        id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
        name: "Main CI",
        target: WindowBinding(
          bundleID: "com.example.ci",
          titleMatch: .contains("Build"),
          windowIDHint: 42,
          lastKnownBounds: CGRect(x: 10, y: 20, width: 300, height: 200)
        ),
        rect: CGRect(x: 1, y: 2, width: 30, height: 40),
        sensitivity: 0.7,
        tickIntervalSeconds: 1,
        command: "notify",
        armed: true
      ),
      Watcher(
        id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
        name: "Chat badge",
        target: WindowBinding(bundleID: "com.example.chat", titleMatch: .exact("Chat")),
        rect: CGRect(x: 5, y: 6, width: 7, height: 8),
        sensitivity: 0.4,
        tickIntervalSeconds: 5,
        command: "echo changed",
        armed: false
      ),
    ]

    try persistence.save(watchers)

    XCTAssertEqual(try persistence.load(), watchers)
  }

  func testLoadMissingFileReturnsEmptyList() throws {
    let directory = try makeTemporaryDirectory()
    let persistence = WatcherPersistence(url: directory.appendingPathComponent("watchers.json"))

    XCTAssertEqual(try persistence.load(), [])
  }

  func testSaveReplacesExistingFile() throws {
    let directory = try makeTemporaryDirectory()
    let url = directory.appendingPathComponent("watchers.json")
    let persistence = WatcherPersistence(url: url)
    let first = makePersistedWatcher(name: "First", armed: true)
    let second = makePersistedWatcher(name: "Second", armed: false)

    try persistence.save([first])
    try persistence.save([second])

    XCTAssertEqual(try persistence.load(), [second])
  }

  private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("PixelWatchTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func makePersistedWatcher(name: String, armed: Bool) -> Watcher {
    Watcher(
      id: UUID(),
      name: name,
      target: WindowBinding(bundleID: "com.example", titleMatch: .regex(".*")),
      rect: CGRect(x: 0, y: 0, width: 10, height: 10),
      sensitivity: 0.7,
      tickIntervalSeconds: 1,
      command: "true",
      armed: armed
    )
  }
}
