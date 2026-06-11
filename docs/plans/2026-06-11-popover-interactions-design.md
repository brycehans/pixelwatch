# Popover Interactions v2 — Design

**Date:** 2026-06-11
**Status:** Accepted

## Overview

Three targeted changes to the popover UI:

1. **Delete button** — overlay `×` on each thumbnail; immediate remove, no confirm.
2. **Drag-to-create** — replace the `+` button with a draggable square; drop location becomes the watch rect.
3. **Gear menu** — gear icon opens a `Menu` with a single "Quit PixelWatch" item.

---

## 1. Delete button on thumbnails

`ThumbnailCellView` gains an `onDelete: () -> Void` closure. A small `×` button is overlaid at the top-right corner using `.overlay(alignment: .topTrailing)`. It is always visible (not hover-gated).

`PopoverGridView` adds `onDelete: (WatcherID) -> Void` and passes a bound closure into each cell.

`PixelWatchAppDelegate` implements the handler:

1. Remove from `watchers` array by ID.
2. Call `store.remove(id:)` — new method on `WatcherStore` (`runtimes.removeValue(forKey:)`). `CaptureStage`'s per-watcher loop self-terminates within one tick: it guards `store.state(for:) == .armed`; after removal that returns `nil`, failing the guard and breaking the loop. No delete-specific bus event needed. `DiffStage`/`DecideStage`/`HookStage` all guard on `store.watcher(for:)` / `store.baseline(for:)` and silently skip events for absent watchers.
3. Call `overlayController.remove(watcherID:)` — new method on `WatcherOverlayController`: `entry.overlay.setVisible(false)` then `entries.removeValue(forKey:)`.
4. Call `persistence.save(watchers)`.
5. Call `refreshPopover()`.

No confirmation dialog. No undo.

---

## 2. Drag-to-create

### Concept

`AddCellView` is replaced by `DragSourceCellView`: an `NSViewRepresentable` wrapping a custom `NSView` subclass (`DragSourceNSView`) that handles AppKit mouse tracking. The visual is identical to the current `+` cell (dashed border, centered `+`).

### Drag lifecycle

**Drag start** (after `>= 5 pt` movement in `mouseDragged`):
- Switch the popover's `behavior` to `.applicationDefined` so it does not auto-dismiss.
- Create a small floating `NSPanel` (borderless, non-activating, level `.floating`) showing the same dashed-border square. This panel follows the cursor as the user drags over any window.
- Start a global `NSEvent` monitor (`.mouseMoved`, `.mouseUp`) so tracking continues even when the cursor leaves the popover.

**Drop** (`mouseUp` event):
- Remove the floating panel.
- Switch popover behavior back to `.transient` and close it.
- Stop the global event monitor.
- Call `onDrop(screenPoint:)` on the delegate with `NSEvent.mouseLocation` from the event.

### Drop handling in the delegate (`PixelWatchAppDelegate`)

`DragSourceCellView` is initialized with `onDrop: (CGPoint) -> Void`. The delegate implements:

1. Use `CGWindowListCopyWindowInfo(.optionOnScreenOnly | .excludeDesktopElements, kCGNullWindowID)` to find the frontmost window whose bounds contain `screenPoint`, excluding PixelWatch's own windows by comparing `kCGWindowOwnerPID` to `ProcessInfo.processInfo.processIdentifier`. This matches the existing pattern in `CGWindowCandidateProvider` and is robust to binary renames.
2. Build a `WindowSnapshot` from that window's `kCGWindowBounds`, `kCGWindowName`, and `kCGWindowOwnerName`.
3. Compute the watch rect: a fixed **200 × 150 pt** rect centered on `screenPoint`, then converted to window-relative coords via the existing `windowRelativeRect(fromScreen:windowBounds:)`.
4. Build a `WatcherDraft` (name = window title, sensitivity = 0.5, command = "", armed = false).
5. Present the configure sheet **standalone** (see below).

If no non-PixelWatch window is found at the drop point, show a brief `NSAlert`.

### Configure sheet reuse

`AppKitConfigureWatcherSheetPresenter` already presents a standalone floating `NSPanel` (`panel.center()` + `makeKeyAndOrderFront`) — it is not attached to the popover. No new presenter is needed.

`present(draft:overlay:)` reads `overlay.frozenRect` to compute the watcher rect. For drag-to-create, inject a `FrozenOverlaySession` stub — a simple struct conforming to `WatcherOverlaySession` whose `frozenRect` is the screen rect derived from the drop point:

```swift
final class FrozenOverlaySession: WatcherOverlaySession {
  let frozenRect: CGRect?
  init(frozenRect: CGRect?) { self.frozenRect = frozenRect }
  func freeze() {}
  func cancel() {}
  func waitForFreeze() async {}
}
```

`WatcherOverlaySession` is `: AnyObject`-constrained, so this must be a `final class`, not a struct.

`PopoverGridView`'s `onAdd` closure is removed; `DragSourceCellView` replaces `AddCellView` entirely. The `NewWatcherCoordinator` focused-window flow is kept intact for the debug-socket `newWatcher` command path.

---

## 3. Gear menu

Replace `Button(action: onQuit)` with a SwiftUI `Menu`:

```swift
Menu {
    Button("Quit PixelWatch", action: onQuit)
} label: {
    Image(systemName: "gearshape").imageScale(.medium)
}
.menuStyle(.borderlessButton)
.fixedSize()
```

`onQuit` closure signature is unchanged. No new callbacks needed.

---

## Changed files summary

| File | Change |
|---|---|
| `PopoverGridView.swift` | Add `onDelete`, replace `AddCellView` with `DragSourceCellView`, swap gear button for `Menu` |
| `PopoverModel.swift` | No change |
| `PixelWatchMain.swift` | Add `onDelete` handler, add `onDrop` handler, wire `StandaloneConfigureWatcherSheetPresenter` |
| `WatcherStore.swift` | Add `remove(id:)` |
| `WatcherOverlayController.swift` | Add `remove(watcherID:)` |
| `ConfigureWatcherSheet.swift` | (read only — reused as-is) |
| New: `DragSourceCellView.swift` | `NSViewRepresentable` + `DragSourceNSView` + floating panel logic |
| New: `FrozenOverlaySession.swift` (or inline) | Stub session carrying pre-computed `frozenRect` for drag path |
