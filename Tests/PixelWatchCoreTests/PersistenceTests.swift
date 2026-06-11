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
    let first = makePersistedWatcher(armed: true)
    let second = makePersistedWatcher(armed: false)

    try persistence.save([first])
    try persistence.save([second])

    XCTAssertEqual(try persistence.load(), [second])
  }

  func testLoadLegacyJsonWithNameFieldSucceeds() throws {
    let directory = try makeTemporaryDirectory()
    let url = directory.appendingPathComponent("watchers.json")
    // Minimal JSON that includes a "name" key that no longer exists in Watcher.
    // titleMatch uses Swift's synthesised encoding: {"exact":{"_0":"Window"}}.
    let json = """
    [{"id":"11111111-1111-1111-1111-111111111111","name":"Legacy Name",\
    "target":{"bundleID":"com.example","titleMatch":{"exact":{"_0":"Window"}},\
    "windowIDHint":null,"lastKnownBounds":null},\
    "rect":[[0,0],[10,10]],\
    "sensitivity":0.5,"tickIntervalSeconds":1,"command":"true","armed":false}]
    """
    try json.write(to: url, atomically: true, encoding: .utf8)
    let loaded = try WatcherPersistence(url: url).load()
    XCTAssertEqual(loaded.count, 1)
    XCTAssertEqual(loaded[0].target.bundleID, "com.example")
  }

  private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("PixelWatchTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func makePersistedWatcher(armed: Bool) -> Watcher {
    Watcher(
      id: UUID(),
      target: WindowBinding(bundleID: "com.example", titleMatch: .regex(".*")),
      rect: CGRect(x: 0, y: 0, width: 10, height: 10),
      sensitivity: 0.7,
      tickIntervalSeconds: 1,
      command: "true",
      armed: armed
    )
  }
}
