import Foundation

public actor EventBus {
  private var subscribers: [UUID: AsyncStream<PixelWatchEvent>.Continuation] = [:]

  public init() {}

  public func subscribe() -> AsyncStream<PixelWatchEvent> {
    let id = UUID()
    return AsyncStream { continuation in
      subscribers[id] = continuation
      continuation.onTermination = { [weak self] _ in
        Task { await self?.removeSubscriber(id) }
      }
    }
  }

  public func publish(_ event: PixelWatchEvent) {
    for continuation in subscribers.values {
      continuation.yield(event)
    }
  }

  public var subscriberCount: Int {
    subscribers.count
  }

  private func removeSubscriber(_ id: UUID) {
    subscribers[id] = nil
  }
}
