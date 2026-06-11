import Observation
import PixelWatchCore

public struct WatcherThumbnailItem: Identifiable, Sendable {
  public let id: WatcherID
  public let state: WatcherState
  public let latestFrame: PixelBuffer?

  public init(id: WatcherID, state: WatcherState, latestFrame: PixelBuffer?) {
    self.id = id
    self.state = state
    self.latestFrame = latestFrame
  }
}

@Observable @MainActor
public final class PopoverModel {
  public var items: [WatcherThumbnailItem] = []

  public init() {}
}
