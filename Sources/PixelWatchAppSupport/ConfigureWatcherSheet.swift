import AppKit
import CoreGraphics
import Foundation
import SwiftUI

// MARK: - SwiftUI sheet view

/// Configure-watcher sheet. Segmented picker selects notification vs shell-command
/// mode; the text field below adapts to whichever mode is active.
struct ConfigureWatcherSheetView: View {
  private enum UIMode { case notification, shell }

  @State private var sensitivity: Double
  @State private var mode: UIMode
  @State private var notificationBody: String
  @State private var shellCommand: String

  let onSave: (Double, CommandMode, Bool) -> Void
  let onCancel: () -> Void

  init(
    draft: WatcherDraft,
    onSave: @escaping (Double, CommandMode, Bool) -> Void,
    onCancel: @escaping () -> Void
  ) {
    _sensitivity = State(initialValue: draft.sensitivity)
    switch draft.commandMode {
    case .notification(let body):
      _mode = State(initialValue: .notification)
      _notificationBody = State(initialValue: body)
      _shellCommand = State(initialValue: "")
    case .shell(let cmd):
      _mode = State(initialValue: .shell)
      _notificationBody = State(initialValue: "")
      _shellCommand = State(initialValue: cmd)
    }
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
        Picker("When it fires", selection: $mode) {
          Text("Notification").tag(UIMode.notification)
          Text("Run a command").tag(UIMode.shell)
        }
        .pickerStyle(.segmented)
        switch mode {
        case .notification:
          TextField("Message", text: $notificationBody)
        case .shell:
          TextField("Command", text: $shellCommand)
        }
      }

      HStack {
        Button("Cancel") { onCancel() }
          .keyboardShortcut(.escape, modifiers: [])
        Spacer()
        Button("Save") { onSave(sensitivity, assembledMode, false) }
          .keyboardShortcut(.return, modifiers: [])
        Button("Save & Arm") { onSave(sensitivity, assembledMode, true) }
          .keyboardShortcut(.return, modifiers: [.command])
      }
    }
    .padding(20)
    .frame(width: 400)
  }

  private var assembledMode: CommandMode {
    switch mode {
    case .notification: .notification(body: notificationBody)
    case .shell: .shell(command: shellCommand)
    }
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

      let save: (Double, CommandMode, Bool) -> Void = { [weak panel] sensitivity, commandMode, armed in
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
          commandMode: commandMode,
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
