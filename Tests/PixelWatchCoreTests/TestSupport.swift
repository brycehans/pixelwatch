import CoreGraphics
import Foundation
@testable import PixelWatchCore

func makeWatcher(sensitivity: Double) -> Watcher {
  Watcher(
    id: UUID(),
    name: "Test Watcher",
    target: WindowBinding(bundleID: "com.example.app", titleMatch: .exact("Window")),
    rect: CGRect(x: 0, y: 0, width: 10, height: 10),
    sensitivity: sensitivity,
    tickIntervalSeconds: 1,
    command: "true",
    armed: false
  )
}

func waitUntil(
  timeoutNanoseconds: UInt64 = 1_000_000_000,
  condition: @escaping () async -> Bool
) async {
  let start = ContinuousClock.now
  while await !condition() {
    if start.duration(to: .now) > .nanoseconds(Int64(timeoutNanoseconds)) {
      return
    }
    await Task.yield()
  }
}

actor EventReader {
  private var events: [PixelWatchEvent] = []
  private var task: Task<Void, Never>?
  private let stream: AsyncStream<PixelWatchEvent>

  init(stream: AsyncStream<PixelWatchEvent>) {
    self.stream = stream
  }

  func start() {
    guard task == nil else { return }
    task = Task {
      var iterator = stream.makeAsyncIterator()
      while let event = await iterator.next() {
        self.append(event)
      }
    }
  }

  deinit {
    task?.cancel()
  }

  func next(
    timeoutNanoseconds: UInt64 = 1_000_000_000,
    matching predicate: @escaping @Sendable (PixelWatchEvent) -> Bool
  ) async -> PixelWatchEvent? {
    let deadline = ContinuousClock.now + .nanoseconds(Int64(timeoutNanoseconds))
    while ContinuousClock.now < deadline {
      if let event = popFirst(matching: predicate) {
        return event
      }
      try? await Task.sleep(nanoseconds: 1_000_000)
    }
    return nil
  }

  private func append(_ event: PixelWatchEvent) {
    events.append(event)
  }

  private func popFirst(matching predicate: (PixelWatchEvent) -> Bool) -> PixelWatchEvent? {
    guard let index = events.firstIndex(where: predicate) else { return nil }
    return events.remove(at: index)
  }
}
