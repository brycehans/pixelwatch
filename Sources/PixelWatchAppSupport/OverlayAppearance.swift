import AppKit

public enum OverlayAppearance {
  public static func borderColor(for state: WatcherState) -> NSColor {
    switch state {
    case .idle:
      // .systemGray (not .gray): NSColor.gray is in the generic-gray colorspace
      // and its .cgColor has 2 components, which CALayer.borderColor misrenders.
      .systemGray
    case .armed:
      .systemGreen
    case .triggered:
      .systemRed
    case .errored:
      .systemOrange
    }
  }

  /// Text shown in the label above each overlay rectangle. State-name only —
  /// the `.errored` case's associated message is reserved for tooltips/logs.
  public static func labelText(for state: WatcherState) -> String {
    switch state {
    case .idle: "idle"
    case .armed: "armed"
    case .triggered: "triggered"
    case .errored: "errored"
    }
  }
}
