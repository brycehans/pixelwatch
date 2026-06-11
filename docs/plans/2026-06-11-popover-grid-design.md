# Popover Thumbnail Grid — Design

**Date:** 2026-06-11
**Status:** Accepted

## Overview

Replace the native `NSMenu` on the menu-bar status item with a custom `NSPopover` containing a SwiftUI grid of watcher thumbnails. Each cell mirrors the live overlay widget: state-name label above, latest captured frame, state-colored border. A "+" cell at the end of the grid triggers new-watcher creation; a gear button opens a minimal menu with "Quit PixelWatch".

## Container and popover mechanics

- `statusItem.menu` is cleared. Instead, the status item button gets an `action` pointing to `togglePopover()` — click opens, click again closes.
- The popover's `contentViewController` is an `NSHostingController` wrapping a SwiftUI root view. Using SwiftUI avoids `NSCollectionView` boilerplate; the ≤20-item grid scale makes data-source reuse unnecessary.
- Popover behavior: `.transient` — dismisses on click outside.
- The `NSHostingController` is created once at app launch and held on the delegate.
- `refreshMenu()` is renamed `refreshPopover()`. Instead of building an `NSMenu` it updates `PopoverModel.items`.

## Data model

```swift
struct WatcherThumbnailItem: Identifiable {
    let id: WatcherID
    let name: String
    let state: WatcherState
    let latestFrame: PixelBuffer?
}

@Observable @MainActor
final class PopoverModel {
    var items: [WatcherThumbnailItem] = []
}
```

`refreshPopover()` rebuilds `items` from the `watchers` array plus `store.snapshot(for:)` for each watcher. Called in the same places `refreshMenu()` was: launch, event monitor callback, `handleWatcherCreated`. No new `WatcherStore` API needed — `WatcherRuntimeSnapshot` already carries `state` and `latestFrame`.

## Thumbnail cell design

Fixed cell size: **120 × 96 pt**.

- **Label strip** (top, 18 pt): dark semi-transparent background (`black @ 65% alpha`), white 11 pt text, state name via `OverlayAppearance.labelText(for:)`.
- **Image area** (remaining 78 pt): `PixelBuffer` rendered as an image, scaled to fill, black background when no frame yet. **3 pt border** in `OverlayAppearance.borderColor(for:)` wraps the image area only.

The "+" cell: same 120 × 96 pt footprint, no label strip, no image — centered `+` at ~28 pt, system-gray border.

## PixelBuffer → displayable image

`PixelBuffer.linearRGB` stores gamma-decoded linear-light floats (3 × Float per pixel). To reconstruct a display-ready image:

1. Raise each channel to `1/2.2` (re-apply sRGB gamma).
2. Clamp to `[0, 1]`, scale to `UInt8`.
3. Pack into RGBA bytes, create `CGImage` via `CGContext`.
4. Wrap in `NSImage`.

This conversion runs on first access per frame, not on every capture tick.

## Grid layout

SwiftUI `LazyVGrid` with adaptive columns, minimum item width 120 pt, spacing 10 pt. Popover fixed width: **380 pt**. Scrolls vertically for overflow. Empty state (no watchers): centered placeholder text "No watchers yet".

## Actions

- **"+" cell** — calls `newWatcherClicked()` via a closure passed into the SwiftUI view.
- **Gear button** (bottom-right of popover) — presents an `NSMenu` with "Quit PixelWatch".
- Both callbacks are plain `@escaping () -> Void` closures; no SwiftUI→AppKit bridge complexity.
