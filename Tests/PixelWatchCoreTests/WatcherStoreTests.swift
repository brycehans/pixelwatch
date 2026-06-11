import CoreGraphics
import XCTest
@testable import PixelWatchCore

final class WatcherStoreTests: XCTestCase {
  func testStoreProjectsRuntimeStateFromBusEvents() async {
    let bus = EventBus()
    let store = WatcherStore(bus: bus)
    let watcher = makeWatcher(sensitivity: 1)
    let baseline = PixelBuffer(width: 1, height: 1, linearRGB: [0, 0, 0])
    let frame = PixelBuffer(width: 1, height: 1, linearRGB: [1, 1, 1])

    await store.add(watcher)
    await store.start()
    await waitUntil { await bus.subscriberCount == 1 }
    await bus.publish(.armed(watcherID: watcher.id, baseline: baseline))
    await waitUntil { await store.baseline(for: watcher.id) == baseline }

    await bus.publish(.diffComputed(watcherID: watcher.id, score: 0.25, frame: frame))
    await bus.publish(.thresholdExceeded(watcherID: watcher.id, score: 0.25, frame: frame))
    await waitUntil { await store.state(for: watcher.id) == .triggered }

    let snapshot = await store.snapshot(for: watcher.id)
    XCTAssertEqual(snapshot?.state, .triggered)
    XCTAssertEqual(snapshot?.baseline, baseline)
    XCTAssertEqual(snapshot?.latestFrame, frame)
    XCTAssertEqual(snapshot?.latestScore, 0.25)
  }

  func testRemoveDeletesSnapshot() async {
    let bus = EventBus()
    let store = WatcherStore(bus: bus)
    let watcher = makeWatcher(sensitivity: 1)
    await store.add(watcher)
    let before = await store.snapshot(for: watcher.id)
    XCTAssertNotNil(before)
    await store.remove(id: watcher.id)
    let after = await store.snapshot(for: watcher.id)
    XCTAssertNil(after)
  }

  func testRemoveIsNoOpForUnknownID() async {
    let bus = EventBus()
    let store = WatcherStore(bus: bus)
    // Must not crash
    await store.remove(id: UUID())
  }
}
