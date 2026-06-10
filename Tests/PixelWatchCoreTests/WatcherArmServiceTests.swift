import CoreGraphics
import XCTest
@testable import PixelWatchCore

final class WatcherArmServiceTests: XCTestCase {
  func testArmCapturesBaselineAndPublishesArmedEvent() async {
    let bus = EventBus()
    let store = WatcherStore(bus: bus)
    let watcher = makeWatcher(sensitivity: 1)
    let baseline = PixelBuffer(width: 1, height: 1, linearRGB: [0, 0, 0])
    let capturer = ArmStubCapturer(result: .success(baseline))

    await store.add(watcher)
    await store.start()
    let events = await EventReader(stream: bus.subscribe())
    await events.start()
    await waitUntil { await bus.subscriberCount == 2 }

    await WatcherArmService.arm(
      watcherID: watcher.id,
      bus: bus,
      store: store,
      windowProvider: ArmStubWindowProvider(candidates: [
        WindowCandidate(
          windowID: 17,
          bundleID: "com.example.app",
          title: "Window",
          bounds: CGRect(x: 0, y: 0, width: 100, height: 100)
        ),
      ]),
      capturer: capturer
    )

    let event = await events.next { event in
      if case .armed = event { return true }
      return false
    }

    XCTAssertEqual(event, .armed(watcherID: watcher.id, baseline: baseline))
    await waitUntil { await store.state(for: watcher.id) == .armed }
    await waitUntil { await store.baseline(for: watcher.id) == baseline }
    let requests = await capturer.recordedRequests()
    XCTAssertEqual(requests, [
      ArmCaptureRequest(windowID: 17, rect: watcher.rect),
    ])
  }

  func testArmPublishesErroredWhenWindowDoesNotResolve() async {
    let bus = EventBus()
    let store = WatcherStore(bus: bus)
    let watcher = makeWatcher(sensitivity: 1)

    await store.add(watcher)
    await store.start()
    let events = await EventReader(stream: bus.subscribe())
    await events.start()
    await waitUntil { await bus.subscriberCount == 2 }

    await WatcherArmService.arm(
      watcherID: watcher.id,
      bus: bus,
      store: store,
      windowProvider: ArmStubWindowProvider(candidates: []),
      capturer: ArmStubCapturer(result: .success(PixelBuffer(width: 1, height: 1, linearRGB: [0, 0, 0])))
    )

    let event = await events.next { event in
      if case .errored = event { return true }
      return false
    }

    guard case let .errored(watcherID, message) = event else {
      return XCTFail("expected errored event")
    }
    XCTAssertEqual(watcherID, watcher.id)
    XCTAssertTrue(message.contains("Window not found"))
    await waitUntil { await store.state(for: watcher.id) == .errored(message) }
  }
}

private struct ArmStubWindowProvider: WindowCandidateProviding {
  let values: [WindowCandidate]

  init(candidates: [WindowCandidate]) {
    values = candidates
  }

  func candidates() -> [WindowCandidate] {
    values
  }
}

private struct ArmCaptureRequest: Equatable, Sendable {
  let windowID: UInt32
  let rect: CGRect
}

private actor ArmStubCapturer: WindowCapturing {
  private var requests: [ArmCaptureRequest] = []
  private let result: Result<PixelBuffer, Error>

  init(result: Result<PixelBuffer, Error>) {
    self.result = result
  }

  func capture(windowID: UInt32, rect: CGRect) async throws -> PixelBuffer {
    requests.append(ArmCaptureRequest(windowID: windowID, rect: rect))
    return try result.get()
  }

  func recordedRequests() -> [ArmCaptureRequest] {
    requests
  }
}
