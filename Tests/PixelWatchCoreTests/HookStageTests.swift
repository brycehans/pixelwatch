import CoreGraphics
import XCTest
@testable import PixelWatchCore

final class HookStageTests: XCTestCase {
  func testThresholdExceededRunsHookAndPublishesLifecycleEvents() async {
    let bus = EventBus()
    let store = WatcherStore(bus: bus)
    let runner = RecordingHookRunner(result: HookResult(exit: 7, stdout: "out", stderr: "err", timedOut: false))
    let watcher = Watcher(
      id: UUID(),
      target: WindowBinding(bundleID: "com.example.ci", titleMatch: .exact("Builds")),
      rect: CGRect(x: 1, y: 2, width: 30, height: 40),
      sensitivity: 0.7,
      tickIntervalSeconds: 1,
      commandMode: .shell(command: "notify \"$WATCH_WINDOW_TITLE\""),
      armed: false
    )
    let frame = PixelBuffer(width: 1, height: 1, linearRGB: [1, 1, 1])

    await store.add(watcher)
    await store.start()
    let hookTask = HookStage.start(bus: bus, store: store, runner: runner)
    let events = await EventReader(stream: bus.subscribe())
    await events.start()
    await waitUntil { await bus.subscriberCount == 3 }
    defer { hookTask.cancel() }

    await bus.publish(.thresholdExceeded(watcherID: watcher.id, score: 0.25, frame: frame))

    let started = await events.next { event in
      if case .hookStarted = event { return true }
      return false
    }
    let finished = await events.next { event in
      if case .hookFinished = event { return true }
      return false
    }
    let invocation = await runner.invocations.first

    guard case let .hookStarted(startedID, command, reason) = started else {
      return XCTFail("expected hookStarted")
    }
    XCTAssertEqual(startedID, watcher.id)
    XCTAssertEqual(command, "notify \"$WATCH_WINDOW_TITLE\"")
    XCTAssertEqual(reason, .pixelChange)

    guard case let .hookFinished(finishedID, exit, stdout, stderr) = finished else {
      return XCTFail("expected hookFinished")
    }
    XCTAssertEqual(finishedID, watcher.id)
    XCTAssertEqual(exit, 7)
    XCTAssertEqual(stdout, "out")
    XCTAssertEqual(stderr, "err")

    XCTAssertEqual(invocation?.command, "notify \"$WATCH_WINDOW_TITLE\"")
    XCTAssertNil(invocation?.env["WATCH_NAME"])
    XCTAssertEqual(invocation?.env["WATCH_WINDOW_TITLE"], "Builds")
    XCTAssertEqual(invocation?.env["WATCH_WINDOW_APP"], "com.example.ci")
    XCTAssertEqual(invocation?.env["WATCH_ID"], watcher.id.uuidString)
    XCTAssertEqual(invocation?.env["WATCH_REASON"], "pixel-change")
    XCTAssertEqual(invocation?.env["WATCH_SCORE"], "0.25")
    XCTAssertEqual(invocation?.env["WATCH_THRESHOLD"], "\(DecideStage.threshold(forSensitivity: watcher.sensitivity))")
    XCTAssertEqual(invocation?.env["WATCH_SENSITIVITY"], "0.7")
    XCTAssertEqual(invocation?.env["WATCH_RECT"], "1.0,2.0,30.0,40.0")
    XCTAssertNotNil(invocation?.env["WATCH_AT"])
  }

  func testWindowVanishedRunsHookWithVanishReason() async {
    let bus = EventBus()
    let store = WatcherStore(bus: bus)
    let runner = RecordingHookRunner(result: HookResult(exit: 0, stdout: "", stderr: "", timedOut: false))
    let watcher = makeWatcher(sensitivity: 1)

    await store.add(watcher)
    await store.start()
    let hookTask = HookStage.start(bus: bus, store: store, runner: runner)
    let events = await EventReader(stream: bus.subscribe())
    await events.start()
    await waitUntil { await bus.subscriberCount == 3 }
    defer { hookTask.cancel() }

    await bus.publish(.windowVanished(watcherID: watcher.id, reason: .appQuit))

    let started = await events.next { event in
      if case .hookStarted = event { return true }
      return false
    }
    let invocation = await runner.invocations.first

    guard case let .hookStarted(_, _, reason) = started else {
      return XCTFail("expected hookStarted")
    }
    XCTAssertEqual(reason, .appQuit)
    XCTAssertEqual(invocation?.env["WATCH_REASON"], "app-quit")
    XCTAssertEqual(invocation?.env["WATCH_SCORE"], "0")
    XCTAssertEqual(invocation?.env["WATCH_THRESHOLD"], "")
  }

  func testNotificationModePostsAndPublishesLifecycleEvents() async {
    let bus = EventBus()
    let store = WatcherStore(bus: bus)
    let runner = RecordingHookRunner(result: HookResult(exit: 0, stdout: "", stderr: "", timedOut: false))
    let poster = RecordingNotificationPoster()
    let watcher = Watcher(
      id: UUID(),
      target: WindowBinding(bundleID: "com.example.ci", titleMatch: .exact("Builds")),
      rect: CGRect(x: 0, y: 0, width: 10, height: 10),
      sensitivity: 0.5,
      tickIntervalSeconds: 1,
      commandMode: .notification(body: "Build done"),
      armed: false
    )
    let frame = PixelBuffer(width: 1, height: 1, linearRGB: [1, 1, 1])

    await store.add(watcher)
    await store.start()
    let hookTask = HookStage.start(bus: bus, store: store, runner: runner, poster: poster)
    let events = await EventReader(stream: bus.subscribe())
    await events.start()
    await waitUntil { await bus.subscriberCount == 3 }
    defer { hookTask.cancel() }

    await bus.publish(.thresholdExceeded(watcherID: watcher.id, score: 0.9, frame: frame))

    let started = await events.next { if case .hookStarted = $0 { return true }; return false }
    let finished = await events.next { if case .hookFinished = $0 { return true }; return false }

    guard case let .hookStarted(startedID, command, reason) = started else {
      return XCTFail("expected hookStarted")
    }
    XCTAssertEqual(startedID, watcher.id)
    XCTAssertEqual(command, "[notification] Build done")
    XCTAssertEqual(reason, .pixelChange)

    guard case let .hookFinished(finishedID, exit, stdout, stderr) = finished else {
      return XCTFail("expected hookFinished")
    }
    XCTAssertEqual(finishedID, watcher.id)
    XCTAssertEqual(exit, 0)
    XCTAssertEqual(stdout, "")
    XCTAssertEqual(stderr, "")

    let invocations = await runner.invocations
    XCTAssertTrue(invocations.isEmpty, "shell runner must not be called for notification mode")

    let posts = await poster.posted
    XCTAssertEqual(posts.count, 1)
    XCTAssertEqual(posts[0].body, "Build done")
    XCTAssertEqual(posts[0].identifier, "\(watcher.id.uuidString)-pixel-change")
  }
}

private actor RecordingNotificationPoster: NotificationPosting {
  private(set) var posted: [(body: String, identifier: String)] = []

  func post(body: String, identifier: String) async {
    posted.append((body: body, identifier: identifier))
  }
}

private actor RecordingHookRunner: HookRunning {
  struct Invocation: Equatable {
    let command: String
    let env: [String: String]
    let timeout: TimeInterval
  }

  private let result: HookResult
  private(set) var invocations: [Invocation] = []

  init(result: HookResult) {
    self.result = result
  }

  func run(command: String, env: [String: String], timeout: TimeInterval) async -> HookResult {
    invocations.append(Invocation(command: command, env: env, timeout: timeout))
    return result
  }
}
