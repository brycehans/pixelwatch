import Foundation

public struct WatcherRuntimeSnapshot: Equatable, Sendable {
  public let watcher: Watcher
  public let state: WatcherState
  public let baseline: PixelBuffer?
  public let latestFrame: PixelBuffer?
  public let latestScore: Double?

  public init(
    watcher: Watcher,
    state: WatcherState,
    baseline: PixelBuffer?,
    latestFrame: PixelBuffer?,
    latestScore: Double?
  ) {
    self.watcher = watcher
    self.state = state
    self.baseline = baseline
    self.latestFrame = latestFrame
    self.latestScore = latestScore
  }
}

private struct WatcherRuntime: Sendable {
  var watcher: Watcher
  var machine: WatcherStateMachine
  var baseline: PixelBuffer?
  var latestFrame: PixelBuffer?
  var latestScore: Double?

  var snapshot: WatcherRuntimeSnapshot {
    WatcherRuntimeSnapshot(
      watcher: watcher,
      state: machine.state,
      baseline: baseline,
      latestFrame: latestFrame,
      latestScore: latestScore
    )
  }
}

public actor WatcherStore {
  private let bus: EventBus
  private var runtimes: [WatcherID: WatcherRuntime] = [:]
  private var subscriptionTask: Task<Void, Never>?

  public init(bus: EventBus) {
    self.bus = bus
  }

  deinit {
    subscriptionTask?.cancel()
  }

  public func add(_ watcher: Watcher) {
    let initialState: WatcherState = watcher.armed ? .armed : .idle
    runtimes[watcher.id] = WatcherRuntime(
      watcher: watcher,
      machine: WatcherStateMachine(watcherID: watcher.id, state: initialState),
      baseline: nil,
      latestFrame: nil,
      latestScore: nil
    )
  }

  public func start() {
    guard subscriptionTask == nil else { return }
    subscriptionTask = Task { [bus] in
      var events = await bus.subscribe().makeAsyncIterator()
      while !Task.isCancelled, let event = await events.next() {
        self.apply(event)
      }
    }
  }

  public func snapshot(for watcherID: WatcherID) -> WatcherRuntimeSnapshot? {
    runtimes[watcherID]?.snapshot
  }

  public func watcher(for watcherID: WatcherID) -> Watcher? {
    runtimes[watcherID]?.watcher
  }

  public func state(for watcherID: WatcherID) -> WatcherState? {
    runtimes[watcherID]?.machine.state
  }

  public func remove(id: WatcherID) {
    runtimes.removeValue(forKey: id)
  }

  public func baseline(for watcherID: WatcherID) -> PixelBuffer? {
    runtimes[watcherID]?.baseline
  }

  private func apply(_ event: PixelWatchEvent) {
    guard var runtime = runtimes[event.watcherID] else { return }

    _ = runtime.machine.apply(event)
    switch event {
    case let .armed(_, baseline):
      runtime.baseline = baseline
      runtime.latestFrame = nil
      runtime.latestScore = nil
      runtime.watcher.armed = true
    case let .frameCaptured(_, frame, _):
      runtime.latestFrame = frame
    case let .diffComputed(_, score, frame),
         let .thresholdExceeded(_, score, frame):
      runtime.latestScore = score
      runtime.latestFrame = frame
    case .paused:
      runtime.baseline = nil
      runtime.watcher.armed = false
    case .windowVanished, .errored:
      runtime.watcher.armed = false
    case .hookStarted, .hookFinished:
      break
    }

    runtimes[event.watcherID] = runtime
  }
}
