# Popover List Layout Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace the popover's thumbnail grid with a 4-column list layout (baseline | status | latest-frame | actions) and shrink the watcher overlay/drag-square from 100×100 / 120×96 to 50×40.

**Architecture:** Pure SwiftUI view replacement inside `PopoverGridView` (public name unchanged). Data model gets one new field (`baseline`). One new callback (`onArm`) added to the view and wired in the app delegate. Size constants in `DragSourceCellView` and `WatcherOverlayController` are the only Core-touching changes.

**Tech Stack:** Swift 6, SwiftUI, AppKit, XCTest

---

## Task 1: Add `baseline` to `WatcherThumbnailItem`

**Files:**
- Modify: `Sources/PixelWatchAppSupport/PopoverModel.swift`
- Modify: `Sources/pixelwatch/PixelWatchMain.swift` (refreshPopover)
- Modify: `Tests/PixelWatchAppSupportTests/PopoverModelTests.swift`

### Step 1: Update the failing tests first

In `PopoverModelTests.swift`, update every `WatcherThumbnailItem` init to include `baseline: nil` (new required field). The tests won't compile until the field exists — that's the "red" signal.

Replace all three `WatcherThumbnailItem(id:state:latestFrame:)` calls with `WatcherThumbnailItem(id:state:baseline:latestFrame:)`:

```swift
// testItemsAreMutable
let item = WatcherThumbnailItem(
  id: UUID(),
  state: .idle,
  baseline: nil,
  latestFrame: nil
)

// testWatcherThumbnailItemIsIdentifiableById
let a = WatcherThumbnailItem(id: id, state: .armed, baseline: nil, latestFrame: nil)
let b = WatcherThumbnailItem(id: id, state: .idle,  baseline: nil, latestFrame: nil)
```

### Step 2: Run to confirm compile failure

```
swift test --filter PixelWatchAppSupportTests.PopoverModelTests
```
Expected: compile error — `extra argument 'baseline' in call` (or missing field).

### Step 3: Add `baseline` field to `WatcherThumbnailItem`

In `Sources/PixelWatchAppSupport/PopoverModel.swift`:

```swift
public struct WatcherThumbnailItem: Identifiable, Sendable {
  public let id: WatcherID
  public let state: WatcherState
  public let baseline: PixelBuffer?
  public let latestFrame: PixelBuffer?

  public init(id: WatcherID, state: WatcherState, baseline: PixelBuffer?, latestFrame: PixelBuffer?) {
    self.id = id
    self.state = state
    self.baseline = baseline
    self.latestFrame = latestFrame
  }
}
```

### Step 4: Update `refreshPopover` in `PixelWatchMain.swift`

Find `refreshPopover()` (around line 396) and pass `snap?.baseline`:

```swift
items.append(WatcherThumbnailItem(
  id: watcher.id,
  state: snap?.state ?? .idle,
  baseline: snap?.baseline,
  latestFrame: snap?.latestFrame
))
```

### Step 5: Run tests

```
swift test --filter PixelWatchAppSupportTests.PopoverModelTests
```
Expected: all 3 tests PASS.

### Step 6: Commit

Write to `tmp/commit-msg.txt`:
```
feat: add baseline field to WatcherThumbnailItem

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
Claude-Session: <session_id>
```
```
git add Sources/PixelWatchAppSupport/PopoverModel.swift
git add Sources/pixelwatch/PixelWatchMain.swift
git add Tests/PixelWatchAppSupportTests/PopoverModelTests.swift
git commit -F tmp/commit-msg.txt
rm tmp/commit-msg.txt
```

---

## Task 2: Add `onArm` callback to `PopoverGridView` and wire it up

**Files:**
- Modify: `Sources/PixelWatchAppSupport/PopoverGridView.swift`
- Modify: `Sources/pixelwatch/PixelWatchMain.swift`

No dedicated test needed — `onArm` is a passthrough callback like `onDelete`. The wiring is covered by the app compiling and running. The arm path itself is tested elsewhere.

### Step 1: Add `onArm` to `PopoverGridView`

In `PopoverGridView.swift`, add to the struct and `init`:

```swift
let onArm: (WatcherID) -> Void

public init(
  model: PopoverModel,
  onDelete: @escaping (WatcherID) -> Void,
  onArm: @escaping (WatcherID) -> Void,
  onDrop: @escaping @MainActor (CGPoint) -> Void,
  onDragStarted: @escaping @MainActor () -> Void = {},
  onQuit: @escaping () -> Void
) {
  self.model = model
  self.onDelete = onDelete
  self.onArm = onArm
  self.onDrop = onDrop
  self.onDragStarted = onDragStarted
  self.onQuit = onQuit
}
```

Pass it into the row view when building row cells (you'll use it in Task 3 — for now just hold the reference).

### Step 2: Add `handleArmWatcher` to `PixelWatchMain.swift`

Add after `handleDeleteWatcher`:

```swift
private func handleArmWatcher(id: WatcherID) {
  Task {
    await WatcherArmService.arm(watcherID: id, bus: bus, store: store)
  }
}
```

### Step 3: Update `popoverController` lazy var in `PixelWatchMain.swift`

Add `onArm` to the `PopoverGridView` init:

```swift
onArm: { [weak self] id in self?.handleArmWatcher(id: id) },
```

### Step 4: Build to confirm no compile errors

```
swift build
```
Expected: BUILD SUCCEEDED.

### Step 5: Commit

Write to `tmp/commit-msg.txt`:
```
feat: add onArm callback to PopoverGridView and wire handleArmWatcher

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
Claude-Session: <session_id>
```
```
git add Sources/PixelWatchAppSupport/PopoverGridView.swift
git add Sources/pixelwatch/PixelWatchMain.swift
git commit -F tmp/commit-msg.txt
rm tmp/commit-msg.txt
```

---

## Task 3: Replace grid with 4-column row layout in `PopoverGridView`

**Files:**
- Modify: `Sources/PixelWatchAppSupport/PopoverGridView.swift`

This is a pure view replacement. The public API (init, callbacks) is unchanged after Task 2.

### Step 1: Replace the `body` and `ThumbnailCellView` in `PopoverGridView.swift`

Remove `ThumbnailCellView` entirely. Replace `PopoverGridView.body` and add a new `WatcherRowView`. Full replacement:

```swift
// Sources/PixelWatchAppSupport/PopoverGridView.swift
import SwiftUI

private let thumbWidth: CGFloat = 50
private let thumbHeight: CGFloat = 40
private let rowPadding: CGFloat = 5
private let borderWidth: CGFloat = 2

public struct PopoverGridView: View {
  @State var model: PopoverModel
  let onDelete: (WatcherID) -> Void
  let onArm: (WatcherID) -> Void
  let onDrop: @MainActor (CGPoint) -> Void
  let onDragStarted: @MainActor () -> Void
  let onQuit: () -> Void

  public init(
    model: PopoverModel,
    onDelete: @escaping (WatcherID) -> Void,
    onArm: @escaping (WatcherID) -> Void,
    onDrop: @escaping @MainActor (CGPoint) -> Void,
    onDragStarted: @escaping @MainActor () -> Void = {},
    onQuit: @escaping () -> Void
  ) {
    self.model = model
    self.onDelete = onDelete
    self.onArm = onArm
    self.onDrop = onDrop
    self.onDragStarted = onDragStarted
    self.onQuit = onQuit
  }

  public var body: some View {
    VStack(spacing: 0) {
      ScrollView {
        LazyVStack(spacing: 0) {
          if model.items.isEmpty {
            Text("No watchers yet")
              .foregroundStyle(.secondary)
              .frame(maxWidth: .infinity)
              .padding(.vertical, 16)
          } else {
            ForEach(model.items) { item in
              WatcherRowView(
                item: item,
                onDelete: { onDelete(item.id) },
                onArm: { onArm(item.id) }
              )
              Divider().padding(.leading, 12)
            }
          }
        }
        .padding(.vertical, 4)
      }

      Divider()

      HStack {
        DragSourceCellView(onDrop: onDrop, onDragStarted: onDragStarted)
          .frame(width: 28, height: 28)
          .padding(.leading, 8)
        Spacer()
        Menu {
          Button("Quit PixelWatch", action: onQuit)
        } label: {
          Image(systemName: "gearshape").imageScale(.medium)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .padding(8)
      }
    }
    .frame(width: 380)
  }
}

private struct WatcherRowView: View {
  let item: WatcherThumbnailItem
  let onDelete: () -> Void
  let onArm: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      // Col 1: baseline
      ThumbnailView(buffer: item.baseline)

      // Col 2: status
      HStack(spacing: 5) {
        Circle()
          .fill(Color(nsColor: OverlayAppearance.borderColor(for: item.state)))
          .frame(width: 8, height: 8)
        Text(OverlayAppearance.labelText(for: item.state))
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      // Col 3: latest frame
      ThumbnailView(buffer: item.latestFrame)

      // Col 4: actions
      HStack(spacing: 4) {
        if item.state == .triggered || item.state == .errored(item.state.errorMessage ?? "") {
          Button(action: onArm) {
            Image(systemName: "arrow.clockwise")
              .foregroundStyle(.secondary)
          }
          .buttonStyle(.plain)
        }
        Button(action: onDelete) {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
      }
      .frame(width: 44, alignment: .trailing)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, rowPadding)
  }
}
```

**Important:** `WatcherState.errored` has an associated `String`. For the re-arm visibility check, match on the enum case pattern correctly:

```swift
// Instead of the placeholder above, use:
var showRearm: Bool {
  switch item.state {
  case .triggered, .errored: return true
  default: return false
  }
}
```

Apply that as a computed property on `WatcherRowView` and use it in the `if` guard for the re-arm button:

```swift
if showRearm {
  Button(action: onArm) { ... }
}
```

Add the thumbnail helper view at the bottom of the file:

```swift
private struct ThumbnailView: View {
  let buffer: PixelBuffer?

  var body: some View {
    ZStack {
      Color.black
      if let img = buffer?.displayImage {
        Image(nsImage: img)
          .resizable()
          .scaledToFill()
      }
    }
    .frame(width: thumbWidth, height: thumbHeight)
    .clipped()
    .cornerRadius(3)
    .overlay(
      RoundedRectangle(cornerRadius: 3)
        .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
    )
  }
}
```

### Step 2: Build

```
swift build
```
Expected: BUILD SUCCEEDED. Fix any Swift 6 Sendable or concurrency errors if they appear (the callbacks are already typed correctly from before).

### Step 3: Run all AppSupport tests

```
swift test --filter PixelWatchAppSupportTests
```
Expected: all PASS. `PopoverModelTests` uses `WatcherThumbnailItem` directly — it doesn't test the view, so no view test changes needed.

### Step 4: Commit

Write to `tmp/commit-msg.txt`:
```
feat: replace popover grid with 4-column list row layout

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
Claude-Session: <session_id>
```
```
git add Sources/PixelWatchAppSupport/PopoverGridView.swift
git commit -F tmp/commit-msg.txt
rm tmp/commit-msg.txt
```

---

## Task 4: Shrink `DragSourceCellView` drop square to 50×40

**Files:**
- Modify: `Sources/PixelWatchAppSupport/DragSourceCellView.swift`

### Step 1: Update `dropSquareSize` constant

At the top of `DragSourceCellView.swift`, change:

```swift
// Before:
private let dropSquareSize = CGSize(width: 120, height: 96)

// After:
private let dropSquareSize = CGSize(width: 50, height: 40)
```

No other changes needed — the rest of `DragSourceNSView` and `DragFloatVisualView` uses `dropSquareSize` and `bounds` throughout, so they resize automatically.

### Step 2: Build

```
swift build
```
Expected: BUILD SUCCEEDED.

### Step 3: Commit

Write to `tmp/commit-msg.txt`:
```
feat: shrink drag-source drop square from 120x96 to 50x40

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
Claude-Session: <session_id>
```
```
git add Sources/PixelWatchAppSupport/DragSourceCellView.swift
git commit -F tmp/commit-msg.txt
rm tmp/commit-msg.txt
```

---

## Task 5: Shrink new-watcher overlay from 100×100 to 50×40

**Files:**
- Modify: `Sources/PixelWatchAppSupport/WatcherOverlayController.swift`
- Modify: `Tests/PixelWatchAppSupportTests/WatcherOverlayControllerTests.swift`

### Step 1: Update the failing test first

In `WatcherOverlayControllerTests.swift`, `testOverlayFollowsWindowAndFreezesOnClick` asserts on the 100×100 initial frame. Update those assertions to 50×40.

The test mouse position is `CGPoint(x: 220, y: 180)`. The overlay is placed with its bottom-right at the cursor: `x = mouse.x - width, y = mouse.y - height`.

Old: `CGRect(x: 120, y: 80, width: 100, height: 100)` (220-100, 180-100)
New: `CGRect(x: 170, y: 140, width: 50, height: 40)` (220-50, 180-40)

```swift
XCTAssertEqual(overlay.frames.first, CGRect(x: 170, y: 140, width: 50, height: 40))
session.freeze()
XCTAssertEqual(session.frozenRect, CGRect(x: 170, y: 140, width: 50, height: 40))
```

Also check `testScreenBottomLeftRectConvertsTopLeftFrame` and `testScreenBottomLeftRectIsInvolutiveOverTwoFlips` — those use arbitrary rect sizes (not the 100×100 constant) so they don't need changes.

### Step 2: Run to confirm test failure

```
swift test --filter PixelWatchAppSupportTests.WatcherOverlayControllerTests/testOverlayFollowsWindowAndFreezesOnClick
```
Expected: FAIL — assertion mismatch (still 100×100 in impl).

### Step 3: Update `begin()` and `tick()` in `WatcherOverlayController.swift`

Extract a file-level constant at the top of `WatcherOverlayController.swift` (before `// MARK: - Protocols`):

```swift
private let watcherOverlaySize = CGSize(width: 50, height: 40)
```

In `begin()`, replace the hardcoded values:

```swift
// Before:
let initialFrame = CGRect(
  x: mouse.x - 100,
  y: mouse.y - 100,
  width: 100,
  height: 100
)

// After:
let initialFrame = CGRect(
  x: mouse.x - watcherOverlaySize.width,
  y: mouse.y - watcherOverlaySize.height,
  width: watcherOverlaySize.width,
  height: watcherOverlaySize.height
)
```

In `DefaultWatcherOverlaySession.tick()`, replace:

```swift
// Before:
let frame = CGRect(x: mouse.x - 100, y: mouse.y - 100, width: 100, height: 100)

// After:
let frame = CGRect(
  x: mouse.x - watcherOverlaySize.width,
  y: mouse.y - watcherOverlaySize.height,
  width: watcherOverlaySize.width,
  height: watcherOverlaySize.height
)
```

**Note:** `watcherOverlaySize` is file-private at the top of `WatcherOverlayController.swift`. `DefaultWatcherOverlaySession` is in the same file, so `tick()` can reference it directly.

### Step 4: Run all overlay tests

```
swift test --filter PixelWatchAppSupportTests.WatcherOverlayControllerTests
```
Expected: all PASS.

### Step 5: Run full test suite

```
swift test
```
Expected: all PASS.

### Step 6: Commit

Write to `tmp/commit-msg.txt`:
```
feat: shrink new-watcher overlay from 100x100 to 50x40

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
Claude-Session: <session_id>
```
```
git add Sources/PixelWatchAppSupport/WatcherOverlayController.swift
git add Tests/PixelWatchAppSupportTests/WatcherOverlayControllerTests.swift
git commit -F tmp/commit-msg.txt
rm tmp/commit-msg.txt
```

---

## Done

After all 5 tasks: `swift test` is all green, `swift build` is clean, and the app has the new row layout. Run `swift run pixelwatch` and open the popover to verify visually.
