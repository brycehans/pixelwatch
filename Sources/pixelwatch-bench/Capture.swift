import Foundation
import ScreenCaptureKit
import CoreGraphics

enum CaptureError: Error {
  case windowNotFound
  case captureFailed(Error)
}

actor Capture {
  /// Look up an SCWindow by `CGWindowID`. Refreshes each call (the bench's
  /// window is stable for a run, but we don't rely on it).
  static func findWindow(cgWindowID: CGWindowID) async throws -> SCWindow {
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    guard let w = content.windows.first(where: { $0.windowID == cgWindowID }) else {
      throw CaptureError.windowNotFound
    }
    return w
  }

  /// Capture the given window at native scale. Returns a CGImage at the
  /// window's full pixel dimensions; callers crop to their rect.
  static func captureWindow(_ window: SCWindow) async throws -> CGImage {
    let filter = SCContentFilter(desktopIndependentWindow: window)
    let cfg = SCStreamConfiguration()
    cfg.width = Int(window.frame.width * 2)   // assume @2x; downsample later anyway
    cfg.height = Int(window.frame.height * 2)
    cfg.pixelFormat = kCVPixelFormatType_32BGRA
    cfg.showsCursor = false
    do {
      return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
    } catch {
      throw CaptureError.captureFailed(error)
    }
  }

  /// Crop a CGImage to a window-relative rect (in points). The image is at
  /// 2x; rect is scaled accordingly.
  static func crop(_ image: CGImage, toPoints rect: CGRect, scale: CGFloat = 2) -> CGImage? {
    let pixelRect = CGRect(
      x: rect.origin.x * scale,
      y: rect.origin.y * scale,
      width: rect.width * scale,
      height: rect.height * scale
    )
    return image.cropping(to: pixelRect)
  }
}
