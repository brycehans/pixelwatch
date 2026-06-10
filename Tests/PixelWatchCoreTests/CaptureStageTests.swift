import CoreGraphics
import XCTest
@testable import PixelWatchCore

final class CaptureStageTests: XCTestCase {
  func testArmedWatcherCapturesFrameAfterTick() async {
    let bus = EventBus()
    let store = WatcherStore(bus: bus)
    let watcher = makeWatcher(sensitivity: 1)
    let baseline = PixelBuffer(width: 1, height: 1, linearRGB: [0, 0, 0])
    let frame = PixelBuffer(width: 1, height: 1, linearRGB: [1, 1, 1])
    let capturer = StubWindowCapturer(result: .success(frame))

    await store.add(watcher)
    await store.start()
    let stageTask = CaptureStage.start(
      bus: bus,
      store: store,
      windowProvider: StubWindowProvider(candidates: [
        WindowCandidate(
          windowID: 99,
          bundleID: "com.example.app",
          title: "Window",
          bounds: CGRect(x: 0, y: 0, width: 100, height: 100)
        ),
      ]),
      capturer: capturer,
      sleeper: OneTickSleeper()
    )
    let events = await EventReader(stream: bus.subscribe())
    await events.start()
    await waitUntil { await bus.subscriberCount == 3 }
    defer { stageTask.cancel() }

    await bus.publish(.armed(watcherID: watcher.id, baseline: baseline))

    let event = await events.next { event in
      if case .frameCaptured = event { return true }
      return false
    }

    guard case let .frameCaptured(watcherID, capturedFrame, _) = event else {
      return XCTFail("expected frameCaptured event")
    }
    XCTAssertEqual(watcherID, watcher.id)
    XCTAssertEqual(capturedFrame, frame)
    let requests = await capturer.recordedRequests()
    XCTAssertEqual(requests, [
      CaptureRequest(windowID: 99, rect: watcher.rect),
    ])
  }

  func testArmedWatcherPublishesWindowVanishedWhenNoCandidateMatches() async {
    let bus = EventBus()
    let store = WatcherStore(bus: bus)
    let watcher = makeWatcher(sensitivity: 1)
    let baseline = PixelBuffer(width: 1, height: 1, linearRGB: [0, 0, 0])

    await store.add(watcher)
    await store.start()
    let stageTask = CaptureStage.start(
      bus: bus,
      store: store,
      windowProvider: StubWindowProvider(candidates: []),
      capturer: StubWindowCapturer(result: .success(baseline)),
      sleeper: OneTickSleeper()
    )
    let events = await EventReader(stream: bus.subscribe())
    await events.start()
    await waitUntil { await bus.subscriberCount == 3 }
    defer { stageTask.cancel() }

    await bus.publish(.armed(watcherID: watcher.id, baseline: baseline))

    let event = await events.next { event in
      if case .windowVanished = event { return true }
      return false
    }

    XCTAssertEqual(event, .windowVanished(watcherID: watcher.id, reason: .windowClosed))
  }
}

private struct StubWindowProvider: WindowCandidateProviding {
  let values: [WindowCandidate]

  init(candidates: [WindowCandidate]) {
    values = candidates
  }

  func candidates() -> [WindowCandidate] {
    values
  }
}

private struct CaptureRequest: Equatable, Sendable {
  let windowID: UInt32
  let rect: CGRect
}

private actor StubWindowCapturer: WindowCapturing {
  private(set) var requests: [CaptureRequest] = []
  private let result: Result<PixelBuffer, Error>

  init(result: Result<PixelBuffer, Error>) {
    self.result = result
  }

  func capture(windowID: UInt32, rect: CGRect) async throws -> PixelBuffer {
    requests.append(CaptureRequest(windowID: windowID, rect: rect))
    return try result.get()
  }

  func recordedRequests() -> [CaptureRequest] {
    requests
  }
}

private actor OneTickSleeper: CaptureSleeping {
  private var sleepCount = 0

  func sleep(seconds _: Double) async throws {
    sleepCount += 1
    if sleepCount > 1 {
      try await Task.sleep(nanoseconds: 1_000_000_000)
    }
  }
}
