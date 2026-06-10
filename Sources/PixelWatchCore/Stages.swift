import Foundation

public enum DiffStage {
  public static func start(bus: EventBus, store: WatcherStore) -> Task<Void, Never> {
    Task {
      var events = await bus.subscribe().makeAsyncIterator()
      while !Task.isCancelled, let event = await events.next() {
        guard case let .frameCaptured(watcherID, frame, _) = event else {
          continue
        }
        guard let baseline = await store.baseline(for: watcherID) else {
          continue
        }
        let score = Diff.score(baseline: baseline, current: frame)
        await bus.publish(.diffComputed(watcherID: watcherID, score: score, frame: frame))
      }
    }
  }
}

extension DecideStage {
  public static func start(bus: EventBus, store: WatcherStore) -> Task<Void, Never> {
    Task {
      var events = await bus.subscribe().makeAsyncIterator()
      while !Task.isCancelled, let event = await events.next() {
        guard case let .diffComputed(watcherID, score, frame) = event else {
          continue
        }
        guard let watcher = await store.watcher(for: watcherID) else {
          continue
        }
        let threshold = threshold(forSensitivity: watcher.sensitivity)
        if score > threshold {
          await bus.publish(.thresholdExceeded(watcherID: watcherID, score: score, frame: frame))
        }
      }
    }
  }
}
