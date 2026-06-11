# Popover List Layout — Design

**Date:** 2026-06-11
**Status:** Accepted

## Problem

The current popover uses a `LazyVGrid` of 120×96 thumbnail cells. Each cell shows only the latest frame, the state label, and a delete button. There is no baseline comparison, no quick re-arm action, and the grid doesn't scale well as watcher count grows.

## Design

### Layout

Replace the grid with a scrollable `LazyVStack` of rows. Each row is a fixed-height `HStack` with four columns:

| Col | Content | Width |
|-----|---------|-------|
| 1 | Baseline thumbnail | 50pt fixed |
| 2 | Color dot + state label (flexible) | ~90pt |
| 3 | Latest-frame thumbnail | 50pt fixed |
| 4 | Action icons | 44pt fixed |

Row height: ~50pt (thumbnail height 40pt + 5pt vertical padding each side).

Both thumbnail cells are 50×40, black background, clipped. A nil buffer renders as a plain dark rectangle.

### Status column (col 2)

An 8pt filled `Circle()` colored via `OverlayAppearance.borderColor(for:)`, with the state label text alongside in `.secondary` style. States: idle (gray), armed (green), triggered (red), errored (orange).

### Action icons (col 4)

- `xmark.circle` — delete, always visible
- `arrow.clockwise` — re-arm, visible only when `state == .triggered || state == .errored`

### Footer bar

An `HStack` divider row replacing the current bottom bar:
- Left: `DragSourceNSView` sized 28×28, renders the `+` glyph. Drag behavior identical to current — blank while dragging, floating skeleton panel follows cursor.
- Right: gear `Menu` (unchanged)

### Size changes

| Location | Old | New |
|----------|-----|-----|
| `dropSquareSize` in `DragSourceCellView.swift` | 120×96 | 50×40 |
| overlay `initialFrame` + `tick()` in `WatcherOverlayController.swift` | 100×100 | 50×40 |

The floating drag-skeleton and the new-watcher overlay both become 50×40 to match the thumbnail size.

### Popover width

Unchanged at 380pt — the four columns fit comfortably with padding.

## Data model changes

### `WatcherThumbnailItem`

Add `baseline: PixelBuffer?` alongside existing `latestFrame`.

### `refreshPopover()` in `PixelWatchMain.swift`

Pass `snap?.baseline` when constructing each `WatcherThumbnailItem`.

### `PopoverGridView`

Add `onArm: (WatcherID) -> Void` callback. Wire in `PixelWatchMain.swift` to a new `handleArmWatcher(id:)` that calls `WatcherArmService.arm(watcherID:bus:store:)`.

## What does NOT change

- `DragSourceNSView` drag logic (start/end/floating panel/monitors) — only the size constant changes
- `OverlayAppearance` — reused as-is
- `PopoverGridView` public name — gutted internally, signature extended
- Gear menu, quit action, `onDrop`/`onDragStarted` callbacks

## Mockup

```
┌─────────────────────────────────────────────────┐
│  ┌──────┐  ● armed      ┌──────┐  ✕            │
│  │▓▓▓▓▓▓│               │▓▓▓▓▓▓│               │
│  └──────┘               └──────┘               │
│  ┌──────┐  ● triggered  ┌──────┐  ↺  ✕         │
│  │▓▓▓▓▓▓│               │▓▓▓▓▓▓│               │
│  └──────┘               └──────┘               │
│  ┌──────┐  ● errored    ┌──────┐  ↺  ✕         │
│  │      │               │      │               │
│  └──────┘               └──────┘               │
├─────────────────────────────────────────────────┤
│  [+]                               ⚙            │
└─────────────────────────────────────────────────┘
```
