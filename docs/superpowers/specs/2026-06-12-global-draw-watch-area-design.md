# Global Draw Watch Area Design

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the popover plus-cell drag/drop creation flow with a click-to-enter draw mode that lets the user draw an arbitrary watch-area rectangle on any normal app window.

**Architecture:** The popover plus button starts a global draw session instead of acting as a drag source. The draw session owns temporary full-screen AppKit UI for window inference, outside-window dimming, rectangle preview, cancellation, and completion. On completion it hands the existing configuration sheet a `WatcherDraft` plus a frozen overlay session carrying the chosen screen rect, so persistence and watcher creation continue through the existing save path.

**Tech Stack:** Swift, AppKit, SwiftUI, CoreGraphics, existing `PixelWatchAppSupport` and `PixelWatchCore` models.

---

## Behavior

### Entry Point

The popover footer plus control is a click target.

- Clicking `+` hides the popover and enters draw mode.
- The old “drag the plus square out of the popover” interaction is removed from the primary UI.
- Debug URL `dropAt` behavior may remain for automation compatibility, but it is no longer the visible new-watcher interaction.

### Window Inference

Draw mode waits for the user's first mouse-down.

- The mouse-down point is converted from AppKit bottom-left screen coordinates to CG top-left screen coordinates.
- The app resolves the frontmost normal app window under that point using the existing CG window-list rules: layer `0`, not PixelWatch's own process, on-screen, valid bounds, valid window number.
- The chosen window does not need to be the focused/key window.
- If no usable window is found, or the point is over PixelWatch UI, desktop, menu bar, or another invalid/non-normal surface, the app exits draw mode and shows the existing no-window alert path.

### Visual Feedback

Once a valid window is inferred, draw mode makes the active drawing bounds obvious.

- The temporary draw UI darkens everything outside the inferred window bounds to the screen edge in every direction.
- The inferred window area itself remains undimmed.
- The in-progress rectangle is drawn with the same visual language as watcher overlays: border plus optional label strip.
- While drawing, the label may show live dimensions. After freeze and watcher creation, the runtime overlay returns to the normal state label behavior.

### Rectangle Drawing

The user drags from the initial mouse-down point to the intended opposite corner.

- The rectangle is normalized so dragging in any direction works.
- The rectangle is clamped to the inferred window bounds.
- Releasing the mouse freezes the rectangle.
- Very small accidental rectangles are invalid. Use an 8x8 px minimum; invalid release exits draw mode and shows the same no-window alert path rather than opening the configuration sheet.
- Escape cancels draw mode without showing the configuration sheet and without creating a watcher.

### Configuration And Save

After a valid mouse-up:

1. The temporary draw UI is removed.
2. The existing configuration sheet opens.
3. The sheet receives a `WatcherDraft` for the inferred window.
4. The sheet reads the frozen screen rect through the existing `WatcherOverlaySession.frozenRect` API.
5. On save, the watcher is persisted with the existing window-relative rect conversion.
6. The runtime watcher overlay is restored for the saved watcher using the existing overlay controller path.

## Data Flow

1. User clicks `+` in the popover.
2. App hides the popover and starts a draw session.
3. User mouse-downs on screen.
4. Draw session resolves the normal app window under the mouse-down point.
5. If resolution fails, draw session stops and the no-window alert is shown.
6. If resolution succeeds, the session draws the outside-window dim mask and begins rectangle preview.
7. User drags; the preview rectangle updates, normalized and clamped to the inferred window.
8. User releases the mouse.
9. If the rect is smaller than 8x8 px, draw session stops and the no-window alert is shown.
10. If the rect is valid, the existing configure sheet is shown.
11. On save, the existing watcher creation path persists the watcher and restores the runtime overlay.

## Components

### Popover Plus Control

The SwiftUI footer plus control becomes a button-like click target that calls `onNewWatcher`.

- It still renders as a small plus square.
- It no longer creates a floating drag panel.
- The popover keeps the existing gear menu and watcher list behavior.

### Draw Session

A new AppKit-backed draw session owns temporary UI and event handling.

- It can be started from the app delegate.
- It resolves the target window from the initial mouse-down point.
- It reports either a valid selection or cancellation/failure.
- It tears down all monitors/windows in every terminal path.

### Window-Under-Point Resolver

The existing drop-target window-list logic is extracted or reused for global draw mode.

- The resolver must support resolving from an AppKit screen point.
- It must preserve current filtering against PixelWatch's own process and non-normal windows.
- It should be testable without CG APIs by accepting supplied window-info dictionaries.

### Frozen Session

The existing `FrozenOverlaySession` remains the bridge into the configuration sheet.

- It carries the selected screen rect.
- It returns immediately from `waitForFreeze`.
- It does not own runtime overlay UI.

## Error Handling

- Invalid mouse-down target: exit draw mode and show the existing no-window alert.
- Invalid tiny rectangle: exit draw mode and show the existing no-window alert.
- Escape: exit draw mode silently.
- Configuration sheet cancel: do not create a watcher.
- Save failure: keep the current persistence logging behavior.

## Testing

- Unit-test window-under-point resolution for normal windows, own-process windows, off-screen windows, and non-zero layers.
- Unit-test rectangle normalization and clamping for drags in all directions and drags beyond the window edge.
- Unit-test the minimum-size validator.
- Unit-test the popover plus control callback shape where feasible without launching full AppKit UI.
- Keep existing drop-target tests passing for compatibility.
- Run `swift test` after implementation.

## Scope Notes

- This feature does not add post-create resize handles.
- This feature does not add a window overview or Mission Control-style chooser.
- This feature does not change watcher persistence format.
- This feature does not change runtime overlay state colors or labels after a watcher is created.
