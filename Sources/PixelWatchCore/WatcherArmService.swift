import Foundation

public enum WatcherArmService {
  public static func arm(
    watcherID: WatcherID,
    bus: EventBus,
    store: WatcherStore,
    windowProvider: some WindowCandidateProviding = LiveWindowCandidateProvider(),
    capturer: some WindowCapturing = ScreenCaptureKitWindowCapture()
  ) async {
    guard let watcher = await store.watcher(for: watcherID) else {
      return
    }

    guard let candidate = WindowResolver.resolve(
      binding: watcher.target,
      candidates: windowProvider.candidates()
    ) else {
      await bus.publish(.errored(
        watcherID: watcherID,
        message: "Window not found for watcher '\(watcher.target.titleMatch.literalValue)' (\(watcher.target.bundleID))"
      ))
      return
    }

    do {
      let baseline = try await capturer.capture(windowID: candidate.windowID, rect: watcher.rect)
      await bus.publish(.armed(watcherID: watcherID, baseline: baseline))
    } catch {
      await bus.publish(.errored(watcherID: watcherID, message: String(describing: error)))
    }
  }
}
