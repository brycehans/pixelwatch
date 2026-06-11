import CoreGraphics

/// Pre-frozen WatcherOverlaySession for the drag-to-create path.
/// Carries the drop-derived screen rect so AppKitConfigureWatcherSheetPresenter
/// can read frozenRect without a live overlay session.
@MainActor
public final class FrozenOverlaySession: WatcherOverlaySession {
  public let frozenRect: CGRect?

  public init(frozenRect: CGRect?) {
    self.frozenRect = frozenRect
  }

  public func freeze() {}
  public func cancel() {}
  public func waitForFreeze() async {}
}
