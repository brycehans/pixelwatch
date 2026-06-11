# Notification Command Mode — Design

**Date:** 2026-06-11

## Problem

The "Command" text field in the configure-watcher sheet requires users to know how to write a shell notification command. The common case — "tell me when this watcher fires" — should be a one-click default.

## Design

### Model — `CommandMode` enum

Add to `PixelWatchCore/Models.swift`:

```swift
public enum CommandMode: Codable, Equatable, Sendable {
    case shell(String)
    case notification(body: String)
}
```

Replace `Watcher.command: String` with `Watcher.commandMode: CommandMode`.

**Migration:** `Watcher.init(from:)` gets a custom decoder: try decoding `commandMode` first; if absent, read legacy `command: String` and wrap as `.shell(command)`. Existing `watchers.json` files keep working without any schema version bump.

`WatcherDraft.command: String` → `WatcherDraft.commandMode: CommandMode`, defaulting to `.notification(body: "Change found on \(window.title)")`.

### HookStage dispatch

`HookStage` branches on `fire.watcher.commandMode`:

- `.shell(let cmd)` — existing path, unchanged.
- `.notification(let body)` — new path:
  1. Build `UNMutableNotificationContent` with `title = "PixelWatch"`, `body = body`.
  2. Add a `UNNotificationRequest` with identifier `"\(watcher.id.uuidString)-\(Date().timeIntervalSinceReferenceDate)"`.
  3. Publish `hookStarted(command: "[notification] \(body)", reason:)` and `hookFinished(exit: 0, stdout: "", stderr: "")` so the event bus / debug socket stay consistent.

`UserNotifications` is AppKit-free and can be imported in `PixelWatchCore` without layering violations.

### Permission request

`UNUserNotificationCenter.current().requestAuthorization(options: [.alert])` is called once at app launch in `PixelWatchMain.swift`, alongside the existing startup wiring. No lazy-request logic needed in `HookStage`.

### UI — ConfigureWatcherSheet

The form changes from a single `TextField("Command")` to:

```
Sensitivity:   [slider]
When it fires: [ Notification | Run a command ]   ← segmented Picker
               [text field — label + placeholder vary by mode]
```

- **Notification** tab: label "Message", pre-filled with `draft.window.title` interpolated: `"Change found on \(draft.window.title)"`.
- **Run a command** tab: label "Command", empty, placeholder `"/path/to/script.sh"`.

The sheet holds a local `@State var mode: CommandMode` (or a local mirror enum). `onSave` signature becomes `(Double, CommandMode, Bool) -> Void`. `AppKitConfigureWatcherSheetPresenter` constructs `Watcher` with `commandMode` directly.

`WatcherDraft` defaults to `.notification(body: "Change found on \(window.title)")` so the sheet opens on the Notification tab with the right prefill.

### Propagation of `command` references

Anywhere `watcher.command` is read today:
- `HookStage` — replaced with `commandMode` switch.
- `hookStarted` event `command:` param — pass derived display string (e.g. `"[notification] BODY"` or raw shell string).
- `WatcherDraft.command` — becomes `commandMode`.
- `ConfigureWatcherSheetView` / presenter — updated to use `commandMode`.

### Tests

- `WatcherStateMachineTests` / persistence tests: add round-trip cases for both `.shell` and `.notification` modes, plus the legacy-`command` migration decode.
- `HookStageTests` (or equivalent): assert notification path publishes correct `hookStarted`/`hookFinished` events and does not call the shell runner.
- `ConfigureWatcherSheet` snapshot / interaction tests: assert segmented picker toggles text field label and placeholder.

## Out of scope

- Sound, subtitle, or other `UNNotificationContent` fields — body only for now.
- Edit-existing-watcher flow — sheet is new-watcher only today.
- Notification grouping / thread identifiers.
