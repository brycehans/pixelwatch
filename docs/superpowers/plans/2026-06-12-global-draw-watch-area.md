# Global Draw Watch Area Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the visible popover plus drag/drop flow with click-to-enter draw mode for arbitrary watch-area rectangles on any normal app window.

**Architecture:** Add small testable geometry and window-resolution helpers, then add an AppKit draw session that owns temporary full-screen UI and event monitors. Wire the popover plus button to start that session and reuse the existing configure-sheet plus `FrozenOverlaySession` save path.

**Tech Stack:** Swift, AppKit, SwiftUI, CoreGraphics, XCTest.

---

## File Structure

- Modify `Sources/PixelWatchAppSupport/DropTargetResolver.swift`: expose a general window-under-point resolver that can be reused by draw mode.
- Create `Sources/PixelWatchAppSupport/DrawSelection.swift`: pure rectangle normalization, clamping, and minimum-size validation.
- Create `Tests/PixelWatchAppSupportTests/DrawSelectionTests.swift`: focused tests for draw geometry.
- Create `Sources/PixelWatchAppSupport/WatchAreaDrawSession.swift`: AppKit temporary draw overlay, dim mask, event handling, and async result.
- Create `Tests/PixelWatchAppSupportTests/WatchAreaDrawSessionTests.swift`: unit-test selection result handling where possible without real global monitors.
- Modify `Sources/PixelWatchAppSupport/DragSourceCellView.swift`: replace drag-source behavior with a click plus control callback.
- Modify `Tests/PixelWatchAppSupportTests/DragSourceCellViewTests.swift`: replace drag cancellation tests with click-callback and drawing tests for the plus visual.
- Modify `Sources/PixelWatchAppSupport/PopoverGridView.swift`: rename callbacks from drag/drop to new watcher start.
- Modify `Sources/pixelwatch/PixelWatchMain.swift`: start draw mode, handle invalid selection alert, present configure sheet, and restore overlay after save.

## Tasks

### Task 1: Pure Draw Geometry

**Files:**
- Create: `Sources/PixelWatchAppSupport/DrawSelection.swift`
- Test: `Tests/PixelWatchAppSupportTests/DrawSelectionTests.swift`

- [ ] **Step 1: Write failing tests**

Create tests for normalized drag directions, clamping to a window, and the 8x8 minimum.

- [ ] **Step 2: Run red test**

Run: `swift test --filter DrawSelectionTests`

Expected: compile failure because `DrawSelection` does not exist.

- [ ] **Step 3: Implement `DrawSelection`**

Add a small public enum/struct with:

```swift
public enum DrawSelection {
  public static let minimumSize = CGSize(width: 8, height: 8)

  public static func rect(from start: CGPoint, to end: CGPoint, clampedTo bounds: CGRect) -> CGRect {
    let raw = CGRect(
      x: min(start.x, end.x),
      y: min(start.y, end.y),
      width: abs(end.x - start.x),
      height: abs(end.y - start.y)
    )
    let minX = max(bounds.minX, raw.minX)
    let minY = max(bounds.minY, raw.minY)
    let maxX = min(bounds.maxX, raw.maxX)
    let maxY = min(bounds.maxY, raw.maxY)
    return CGRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
  }

  public static func isValid(_ rect: CGRect) -> Bool {
    rect.width >= minimumSize.width && rect.height >= minimumSize.height
  }
}
```

- [ ] **Step 4: Run green test**

Run: `swift test --filter DrawSelectionTests`

Expected: pass.

### Task 2: Reusable Window-Under-Point Resolver

**Files:**
- Modify: `Sources/PixelWatchAppSupport/DropTargetResolver.swift`
- Modify: `Tests/PixelWatchAppSupportTests/DropTargetResolverTests.swift`

- [ ] **Step 1: Write failing tests**

Add tests that resolving an AppKit point ignores own-process layer-0 windows, ignores off-screen windows, ignores non-zero layers, and selects any valid normal app window under the mouse point.

- [ ] **Step 2: Run red test**

Run: `swift test --filter DropTargetResolverTests`

Expected: failure for off-screen handling until resolver checks `kCGWindowIsOnscreen`.

- [ ] **Step 3: Update resolver**

Keep `resolve(appKitDropPoint:screenHeight:windowInfo:)`, and ensure it filters:

```swift
let isOnscreen = CGWindowDictParser.boolValue(info[String(kCGWindowIsOnscreen)]) ?? true
guard isOnscreen else { continue }
```

Preserve the existing layer, own-PID, bounds, containment, and window-number filters.

- [ ] **Step 4: Run green test**

Run: `swift test --filter DropTargetResolverTests`

Expected: pass.

### Task 3: Draw Session Result And AppKit UI

**Files:**
- Create: `Sources/PixelWatchAppSupport/WatchAreaDrawSession.swift`
- Test: `Tests/PixelWatchAppSupportTests/WatchAreaDrawSessionTests.swift`

- [ ] **Step 1: Write failing tests**

Test that a valid drag result returns a `WindowSnapshot` and frozen screen rect, that tiny selections are invalid, and that invalid mouse-down returns `.invalidWindow`.

- [ ] **Step 2: Run red test**

Run: `swift test --filter WatchAreaDrawSessionTests`

Expected: compile failure because `WatchAreaDrawSession` does not exist.

- [ ] **Step 3: Implement public result types and testable resolver path**

Add:

```swift
public enum WatchAreaDrawFailure: Equatable, Sendable {
  case cancelled
  case invalidWindow
  case invalidSelection
}

public struct WatchAreaDrawSelection: Equatable, Sendable {
  public let window: WindowSnapshot
  public let screenRect: CGRect
}
```

Implement a `WatchAreaDrawSession` with a live `start() async -> Result<WatchAreaDrawSelection, WatchAreaDrawFailure>` and internal methods that tests can drive directly.

- [ ] **Step 4: Implement live overlay**

Use transparent borderless panels per screen. On valid mouse-down, draw four dim regions around `window.bounds`; while dragging, update a preview layer to `DrawSelection.rect(from:to:clampedTo:)`; on mouse-up, finish or invalid-selection.

- [ ] **Step 5: Run green test**

Run: `swift test --filter WatchAreaDrawSessionTests`

Expected: pass.

### Task 4: Popover Plus Click Entry

**Files:**
- Modify: `Sources/PixelWatchAppSupport/DragSourceCellView.swift`
- Modify: `Sources/PixelWatchAppSupport/PopoverGridView.swift`
- Modify: `Tests/PixelWatchAppSupportTests/DragSourceCellViewTests.swift`

- [ ] **Step 1: Write failing tests**

Replace drag-specific tests with a test that `DragSourceNSView.mouseUp` calls `onClick` once, and keep the plus visual render test.

- [ ] **Step 2: Run red test**

Run: `swift test --filter DragSourceCellViewTests`

Expected: compile failure or assertion failure until callbacks are renamed.

- [ ] **Step 3: Implement click-only plus view**

`DragSourceCellView` should accept `onClick`, draw the same plus square, and remove floating drag panel state and global mouse-up monitors.

- [ ] **Step 4: Wire popover callback**

`PopoverGridView` should expose `onNewWatcher` and call it from the plus view.

- [ ] **Step 5: Run green test**

Run: `swift test --filter DragSourceCellViewTests`

Expected: pass.

### Task 5: App Delegate Wiring

**Files:**
- Modify: `Sources/pixelwatch/PixelWatchMain.swift`

- [ ] **Step 1: Wire popover to draw mode**

Replace `onDrop` and `onDragStarted` with `onNewWatcher: { handleNewWatcherClick() }`.

- [ ] **Step 2: Implement draw mode handling**

Hide the popover, run `WatchAreaDrawSession.start()`, show the existing no-window alert for `.invalidWindow` and `.invalidSelection`, do nothing for `.cancelled`, and on success present `AppKitConfigureWatcherSheetPresenter` with `FrozenOverlaySession(frozenRect: selection.screenRect)`.

- [ ] **Step 3: Restore overlay after save**

Reuse `handleWatcherCreatedFromDrag(watcher, windowID: selection.window.windowID)`, renaming it if needed to describe frozen-selection creation.

- [ ] **Step 4: Run full verification**

Run: `swift test`

Expected: all tests pass.
