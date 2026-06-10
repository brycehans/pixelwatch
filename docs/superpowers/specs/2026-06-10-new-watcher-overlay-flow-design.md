# New Watcher Overlay Flow Design

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create a fast new-watcher flow that starts from the currently focused key window, shows a 100x100 cursor-following square attached to that window, and lets the user freeze it with one click before configuring and saving the watcher.

**Architecture:** The new-watcher flow is a small coordinator that reads the focused window, shows a transient overlay tied to that window, and hands the chosen window binding plus rect to the existing configuration path. The overlay is not a one-off picker; it is the visual representation of the watcher itself, so it remains visible after arm and throughout the watcher lifecycle. State is conveyed by border color, while position and visibility always follow the target window.

**Tech Stack:** Swift, AppKit, SwiftUI, CoreGraphics, existing `PixelWatchCore` models and persistence.

---

## Behavior

### Entry point

`+ New watcher` uses the current focused key window as its target.

- If there is no usable window, the app shows a standard alert and stops.
- If there is a usable window, the flow begins immediately on that window.
- There is no separate window-picker step in v1.

### Rectangle selection

The user sees a 100x100 square overlay that follows the mouse cursor over the focused window.

- The square is the default rect.
- There are no resize handles in v1.
- The user clicks once to freeze the square in place.
- The frozen square becomes the watcher rect, relative to the target window.

### Persistent overlay

The square stays visible after the watcher is created and after it is armed.

- The overlay remains attached to the target window.
- It tracks the window’s position and resize changes.
- Its visibility matches the target window’s own visibility.
- When the window moves or resizes, the square stays pinned to the same window-relative point.
- Manual removal is allowed later, but the flow does not auto-hide overlays after firing.

### State indication

The overlay border color communicates watcher state.

- `idle`: gray
- `armed`: green
- `triggered`: red
- `errored`: amber

The color is the only in-flow state signal. The overlay does not change size or shape when state changes.

## Data flow

1. User clicks `+ New watcher`.
2. App inspects the focused key window.
3. If no window exists, show an alert and stop.
4. If a window exists, start the 100x100 cursor-following square over that window.
5. User clicks once to freeze the square.
6. The chosen window binding and rect are handed to the existing configure/save flow.
7. On save, the overlay remains visible and continues to reflect runtime state by border color.

## Error handling

- Missing key window: alert and return early.
- Window becomes unavailable while creating the watcher: stop the flow and surface the same alert path.
- Overlay creation or tracking failure: fail closed and avoid saving an incomplete watcher.

## Testing

- Verify the no-window path shows an alert and does not open the overlay.
- Verify a focused window starts the 100x100 cursor-following square immediately.
- Verify the click freezes the rect and hands the window-relative geometry to the save flow.
- Verify overlay position updates when the target window moves or resizes.
- Verify overlay visibility follows the target window’s visibility.
- Verify state color changes for `idle`, `armed`, `triggered`, and `errored`.

## Scope notes

- This design replaces the earlier window-picker and rect-picker split for v1.
- The overlay is part of the watcher’s runtime presence, not just a creation aid.
- The flow does not add resize handles, Mission Control-style window overviews, or post-fire hiding.
