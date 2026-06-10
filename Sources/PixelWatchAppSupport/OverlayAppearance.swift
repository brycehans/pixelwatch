import AppKit

public enum OverlayAppearance {
  public static func borderColor(for state: WatcherState) -> NSColor {
    switch state {
    case .idle:
      .gray
    case .armed:
      .systemGreen
    case .triggered:
      .systemRed
    case .errored:
      .systemOrange
    }
  }
}
