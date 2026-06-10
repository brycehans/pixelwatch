import AppKit
import CoreGraphics
import CoreVideo
import Foundation
import ScreenCaptureKit

public protocol WindowCapturing: Sendable {
  func capture(windowID: UInt32, rect: CGRect) async throws -> PixelBuffer
}

public protocol CaptureSleeping: Sendable {
  func sleep(seconds: Double) async throws
}

public struct TaskCaptureSleeper: CaptureSleeping {
  public init() {}

  public func sleep(seconds: Double) async throws {
    let nanoseconds = UInt64(max(0, seconds) * 1_000_000_000)
    try await Task.sleep(nanoseconds: nanoseconds)
  }
}

public enum CaptureError: Error, Equatable {
  case windowNotFound(UInt32)
  case cropFailed(CGRect)
  case captureFailed(String)
}

public struct ScreenDescriptor: Equatable, Sendable {
  public let frame: CGRect
  public let backingScaleFactor: CGFloat

  public init(frame: CGRect, backingScaleFactor: CGFloat) {
    self.frame = frame
    self.backingScaleFactor = backingScaleFactor
  }
}

public enum CaptureGeometry {
  public static func pixelCropRect(windowRelativeRect: CGRect, scale: CGFloat) -> CGRect {
    CGRect(
      x: windowRelativeRect.origin.x * scale,
      y: windowRelativeRect.origin.y * scale,
      width: windowRelativeRect.width * scale,
      height: windowRelativeRect.height * scale
    )
  }

  public static func scale(
    forWindowFrame windowFrame: CGRect,
    screens: [ScreenDescriptor]
  ) -> CGFloat {
    guard let best = screens.max(by: { lhs, rhs in
      lhs.frame.intersection(windowFrame).area < rhs.frame.intersection(windowFrame).area
    }) else {
      return 1
    }

    return best.backingScaleFactor
  }
}

public struct ScreenCaptureKitWindowCapture: WindowCapturing {
  public init() {}

  public func capture(windowID: UInt32, rect: CGRect) async throws -> PixelBuffer {
    let window = try await findWindow(windowID: windowID)
    let scale = CaptureGeometry.scale(
      forWindowFrame: window.frame,
      screens: NSScreen.screens.map(ScreenDescriptor.init(screen:))
    )
    let image = try await captureWindow(window, scale: scale)
    guard let cropped = Self.crop(image, toWindowRelativeRect: rect, scale: scale) else {
      throw CaptureError.cropFailed(rect)
    }
    return Diff.makeBuffer(from: cropped)
  }

  private func findWindow(windowID: UInt32) async throws -> SCWindow {
    let content = try await SCShareableContent.excludingDesktopWindows(
      false,
      onScreenWindowsOnly: false
    )
    guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
      throw CaptureError.windowNotFound(windowID)
    }
    return window
  }

  private func captureWindow(_ window: SCWindow, scale: CGFloat) async throws -> CGImage {
    let filter = SCContentFilter(desktopIndependentWindow: window)
    let configuration = SCStreamConfiguration()
    configuration.width = max(1, Int((window.frame.width * scale).rounded()))
    configuration.height = max(1, Int((window.frame.height * scale).rounded()))
    configuration.pixelFormat = kCVPixelFormatType_32BGRA
    configuration.showsCursor = false

    do {
      return try await SCScreenshotManager.captureImage(
        contentFilter: filter,
        configuration: configuration
      )
    } catch {
      throw CaptureError.captureFailed(String(describing: error))
    }
  }

  static func crop(_ image: CGImage, toWindowRelativeRect rect: CGRect, scale: CGFloat) -> CGImage? {
    image.cropping(to: CaptureGeometry.pixelCropRect(windowRelativeRect: rect, scale: scale).integral)
  }
}

private extension ScreenDescriptor {
  init(screen: NSScreen) {
    self.init(frame: screen.frame, backingScaleFactor: screen.backingScaleFactor)
  }
}

private extension CGRect {
  var area: CGFloat {
    guard !isNull, !isEmpty else { return 0 }
    return width * height
  }
}
