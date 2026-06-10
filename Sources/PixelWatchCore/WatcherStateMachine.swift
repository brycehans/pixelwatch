import Foundation

public struct WatcherStateTransition: Equatable, Sendable {
  public let newState: WatcherState
  public let emittedEvents: [PixelWatchEvent]

  public init(newState: WatcherState, emittedEvents: [PixelWatchEvent] = []) {
    self.newState = newState
    self.emittedEvents = emittedEvents
  }
}

public struct WatcherStateMachine: Sendable {
  public let watcherID: WatcherID
  public private(set) var state: WatcherState

  public init(watcherID: WatcherID, state: WatcherState) {
    self.watcherID = watcherID
    self.state = state
  }

  public mutating func apply(_ event: PixelWatchEvent) -> WatcherStateTransition {
    guard event.watcherID == watcherID else {
      return WatcherStateTransition(newState: state)
    }

    let nextState: WatcherState
    switch event {
    case .armed:
      nextState = .armed
    case .thresholdExceeded, .windowVanished:
      nextState = state == .armed ? .triggered : state
    case .paused:
      nextState = .idle
    case let .errored(_, message):
      nextState = .errored(message)
    case .frameCaptured, .diffComputed, .hookStarted, .hookFinished:
      nextState = state
    }

    state = nextState
    return WatcherStateTransition(newState: nextState)
  }
}

public enum DecideStage {
  public static func threshold(forSensitivity sensitivity: Double) -> Double {
    let clamped = min(1, max(0, sensitivity))
    return 0.001 * pow(200, 1 - clamped)
  }
}
