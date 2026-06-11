import AppKit
import CoreGraphics
import Foundation
import SwiftUI

// MARK: - SwiftUI sheet view

/// V1 configure-watcher sheet. Exposes sensitivity and command, and
/// two action buttons: Save (armed=false) and Save & Arm (armed=true).
struct ConfigureWatcherSheetView: View {
  @State private var sensitivity: Double
  @State private var command: String

  let onSave: (Double, String, Bool) -> Void
  let onCancel: () -> Void

  init(
    draft: WatcherDraft,
    onSave: @escaping (Double, String, Bool) -> Void,
    onCancel: @escaping () -> Void
  ) {
    _sensitivity = State(initialValue: draft.sensitivity)
    _command = State(initialValue: draft.command)
    self.onSave = onSave
    self.onCancel = onCancel
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("New Watcher")
        .font(.headline)

      Form {
        VStack(alignment: .leading, spacing: 4) {
          Text("Sensitivity: \(String(format: "%.2f", sensitivity))")
          Slider(value: $sensitivity, in: 0...1)
        }
        TextField("Command", text: $command)
      }

      HStack {
        Button("Cancel") {
          onCancel()
        }
        .keyboardShortcut(.escape, modifiers: [])

        Spacer()

        Button("Save") {
          onSave(sensitivity, command, false)
        }
        .keyboardShortcut(.return, modifiers: [])

        Button("Save & Arm") {
          onSave(sensitivity, command, true)
        }
        .keyboardShortcut(.return, modifiers: [.command])
      }
    }
    .padding(20)
    .frame(width: 400)
  }
}

// MARK: - AppKit presenter

/// Presents `ConfigureWatcherSheetView` as a modal sheet on the key window,
/// or as a free-standing window if no suitable parent window is available.
@MainActor
public final class AppKitConfigureWatcherSheetPresenter: ConfigureWatcherSheetPresenting {

  public init() {}

  public func present(
    draft: WatcherDraft,
    overlay: any WatcherOverlaySession
  ) async -> Watcher? {
    await withCheckedContinuation { continuation in
      let panel = NSPanel(
        contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
        styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
        backing: .buffered,
        defer: false
      )
      panel.title = "New Watcher"
      panel.isReleasedWhenClosed = false
      panel.level = .floating

      var resumed = false

      let save: (Double, String, Bool) -> Void = { [weak panel] sensitivity, command, armed in
        guard !resumed else { return }
        resumed = true
        panel?.close()

        // frozenRect is in screen coords; persistence + Capture want window-relative.
        let screenRect = overlay.frozenRect ?? CGRect(x: 0, y: 0, width: 100, height: 100)
        let rect = windowRelativeRect(fromScreen: screenRect, windowBounds: draft.window.bounds)
        let target = WindowBinding(
          bundleID: draft.window.bundleID,
          titleMatch: .exact(draft.window.title),
          windowIDHint: draft.window.windowID,
          lastKnownBounds: draft.window.bounds
        )
        let watcher = Watcher(
          id: UUID(),
          target: target,
          rect: rect,
          sensitivity: sensitivity,
          tickIntervalSeconds: 1.0,
          command: command,
          armed: armed
        )
        continuation.resume(returning: watcher)
      }

      let cancel: () -> Void = { [weak panel] in
        guard !resumed else { return }
        resumed = true
        panel?.close()
        continuation.resume(returning: nil)
      }

      let view = ConfigureWatcherSheetView(draft: draft, onSave: save, onCancel: cancel)
      let hosting = NSHostingController(rootView: view)
      panel.contentViewController = hosting
      panel.center()
      panel.makeKeyAndOrderFront(nil)
    }
  }
}
