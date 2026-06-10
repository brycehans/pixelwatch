import Foundation

public enum CaptureStage {
  public static func start(
    bus: EventBus,
    store: WatcherStore,
    windowProvider: some WindowCandidateProviding = LiveWindowCandidateProvider(),
    capturer: some WindowCapturing = ScreenCaptureKitWindowCapture(),
    sleeper: some CaptureSleeping = TaskCaptureSleeper()
  ) -> Task<Void, Never> {
    Task {
      var activeTasks: [WatcherID: Task<Void, Never>] = [:]
      var events = await bus.subscribe().makeAsyncIterator()

      while !Task.isCancelled, let event = await events.next() {
        switch event {
        case let .armed(watcherID, _):
          guard let watcher = await store.watcher(for: watcherID) else {
            continue
          }
          activeTasks[watcherID]?.cancel()
          activeTasks[watcherID] = captureLoop(
            watcher: watcher,
            bus: bus,
            store: store,
            windowProvider: windowProvider,
            capturer: capturer,
            sleeper: sleeper
          )
        case let .paused(watcherID, _),
             let .thresholdExceeded(watcherID, _, _),
             let .windowVanished(watcherID, _),
             let .errored(watcherID, _):
          activeTasks[watcherID]?.cancel()
          activeTasks[watcherID] = nil
        case .frameCaptured,
             .diffComputed,
             .hookStarted,
             .hookFinished:
          break
        }
      }

      activeTasks.values.forEach { $0.cancel() }
    }
  }

  private static func captureLoop(
    watcher: Watcher,
    bus: EventBus,
    store: WatcherStore,
    windowProvider: some WindowCandidateProviding,
    capturer: some WindowCapturing,
    sleeper: some CaptureSleeping
  ) -> Task<Void, Never> {
    Task {
      while !Task.isCancelled {
        do {
          try await sleeper.sleep(seconds: watcher.tickIntervalSeconds)
        } catch {
          break
        }

        guard await store.state(for: watcher.id) == .armed else {
          break
        }

        guard let candidate = WindowResolver.resolve(
          binding: watcher.target,
          candidates: windowProvider.candidates()
        ) else {
          await bus.publish(.windowVanished(watcherID: watcher.id, reason: .windowClosed))
          break
        }

        do {
          let frame = try await capturer.capture(windowID: candidate.windowID, rect: watcher.rect)
          await bus.publish(.frameCaptured(watcherID: watcher.id, frame: frame, at: Date()))
        } catch {
          await bus.publish(.errored(watcherID: watcher.id, message: String(describing: error)))
          break
        }
      }
    }
  }
}

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

public enum HookStage {
  public static func start(
    bus: EventBus,
    store: WatcherStore,
    runner: some HookRunning = LiveHookRunner(),
    timeout: TimeInterval = 30
  ) -> Task<Void, Never> {
    Task {
      var events = await bus.subscribe().makeAsyncIterator()
      while !Task.isCancelled, let event = await events.next() {
        guard let fire = await FireContext(event: event, store: store) else {
          continue
        }
        await bus.publish(.hookStarted(
          watcherID: fire.watcher.id,
          command: fire.watcher.command,
          reason: fire.reason
        ))
        let result = await runner.run(
          command: fire.watcher.command,
          env: fire.env,
          timeout: timeout
        )
        await bus.publish(.hookFinished(
          watcherID: fire.watcher.id,
          exit: result.exit,
          stdout: result.stdout,
          stderr: result.stderr
        ))
      }
    }
  }
}

private struct FireContext: Sendable {
  let watcher: Watcher
  let reason: FireReason
  let env: [String: String]

  init?(event: PixelWatchEvent, store: WatcherStore) async {
    switch event {
    case let .thresholdExceeded(watcherID, score, _):
      guard let watcher = await store.watcher(for: watcherID) else { return nil }
      self.watcher = watcher
      reason = .pixelChange
      env = HookEnvironment.make(
        watcher: watcher,
        reason: .pixelChange,
        score: score,
        threshold: DecideStage.threshold(forSensitivity: watcher.sensitivity)
      )
    case let .windowVanished(watcherID, vanishReason):
      guard let watcher = await store.watcher(for: watcherID) else { return nil }
      self.watcher = watcher
      reason = vanishReason == .appQuit ? .appQuit : .windowVanished
      env = HookEnvironment.make(
        watcher: watcher,
        reason: reason,
        score: 0,
        threshold: nil
      )
    default:
      return nil
    }
  }
}

private enum HookEnvironment {
  static func make(
    watcher: Watcher,
    reason: FireReason,
    score: Double,
    threshold: Double?
  ) -> [String: String] {
    [
      "WATCH_NAME": watcher.name,
      "WATCH_ID": watcher.id.uuidString,
      "WATCH_AT": ISO8601DateFormatter().string(from: Date()),
      "WATCH_REASON": reason.environmentValue,
      "WATCH_SCORE": format(score),
      "WATCH_THRESHOLD": threshold.map(format) ?? "",
      "WATCH_SENSITIVITY": format(watcher.sensitivity),
      "WATCH_WINDOW_APP": watcher.target.bundleID,
      "WATCH_WINDOW_TITLE": watcher.target.titleMatch.literalValue,
      "WATCH_RECT": "\(watcher.rect.origin.x),\(watcher.rect.origin.y),\(watcher.rect.width),\(watcher.rect.height)",
      "WATCH_THUMB": "",
      "WATCH_BASELINE_THUMB": "",
    ]
  }

  private static func format(_ value: Double) -> String {
    value.rounded() == value ? String(Int(value)) : String(value)
  }
}

private extension FireReason {
  var environmentValue: String {
    switch self {
    case .pixelChange: "pixel-change"
    case .windowVanished: "window-vanished"
    case .appQuit: "app-quit"
    case .runHookNow: "run-hook-now"
    case .testHook: "test-hook"
    }
  }
}

private extension TitleMatch {
  var literalValue: String {
    switch self {
    case let .exact(value), let .contains(value), let .regex(value):
      value
    }
  }
}
