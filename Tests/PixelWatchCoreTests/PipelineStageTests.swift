import CoreGraphics
import XCTest
@testable import PixelWatchCore

final class PipelineStageTests: XCTestCase {
  func testFrameCapturedFlowsThroughDiffDecideAndStoreTrigger() async {
    let bus = EventBus()
    let store = WatcherStore(bus: bus)
    let watcher = makeWatcher(sensitivity: 1)
    let baseline = PixelBuffer(width: 2, height: 2, linearRGB: Array(repeating: 0, count: 12))
    let current = PixelBuffer(width: 2, height: 2, linearRGB: [
      0, 0, 0,
      0, 0, 0,
      0, 0, 0,
      1, 1, 1,
    ])

    await store.add(watcher)
    await store.start()
    let diffTask = DiffStage.start(bus: bus, store: store)
    let decideTask = DecideStage.start(bus: bus, store: store)
    let events = await EventReader(stream: bus.subscribe())
    await events.start()
    await waitUntil { await bus.subscriberCount == 4 }
    defer {
      diffTask.cancel()
      decideTask.cancel()
    }

    await bus.publish(.armed(watcherID: watcher.id, baseline: baseline))
    await waitUntil { await store.baseline(for: watcher.id) == baseline }

    await bus.publish(.frameCaptured(watcherID: watcher.id, frame: current, at: Date()))

    let diffEvent = await events.next { event in
      if case .diffComputed = event { return true }
      return false
    }
    let thresholdEvent = await events.next { event in
      if case .thresholdExceeded = event { return true }
      return false
    }

    guard case let .diffComputed(diffWatcherID, score, _) = diffEvent else {
      return XCTFail("expected diffComputed event")
    }
    XCTAssertEqual(diffWatcherID, watcher.id)
    XCTAssertEqual(score, 0.25, accuracy: 0.0001)

    guard case let .thresholdExceeded(thresholdWatcherID, thresholdScore, _) = thresholdEvent else {
      return XCTFail("expected thresholdExceeded event")
    }
    XCTAssertEqual(thresholdWatcherID, watcher.id)
    XCTAssertEqual(thresholdScore, 0.25, accuracy: 0.0001)
    await waitUntil { await store.state(for: watcher.id) == .triggered }
  }
}
