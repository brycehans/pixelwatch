# Popover Interactions v2 — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a delete button to each watcher thumbnail, replace the `+` button with a drag-to-create flow, and convert the gear button to a proper menu — per `docs/plans/2026-06-11-popover-interactions-design.md`.

**Architecture:** Two new methods on existing actors (`WatcherStore.remove`, `WatcherOverlayController.remove`), one new support type (`FrozenOverlaySession`), one new AppKit drag view (`DragSourceCellView`), and targeted changes to `PopoverGridView` and `PixelWatchMain`. No new stages, no new external dependencies.

**Tech Stack:** Swift 6, SwiftUI (`Menu`, `NSViewRepresentable`, overlay), AppKit (`NSPanel`, `NSEvent` global monitor, `Timer`), CoreGraphics (`CGWindowListCopyWindowInfo`), `CGWindowDictParser` (existing helper), XCTest.

---

### Task 1: WatcherStore.remove(id:)

**Files:**
- Modify: `Sources/PixelWatchCore/WatcherStore.swift`
- Modify: `Tests/PixelWatchCoreTests/WatcherStoreTests.swift`

**Step 1: Write the failing test**

Add to `WatcherStoreTests`:

```swift
func testRemoveDeletesSnapshot() async {
  let bus = EventBus()
  let store = WatcherStore(bus: bus)
  let watcher = makeWatcher(sensitivity: 0.5)
  await store.add(watcher)
  XCTAssertNotNil(await store.snapshot(for: watcher.id))
  await store.remove(id: watcher.id)
  XCTAssertNil(await store.snapshot(for: watcher.id))
}

func testRemoveIsNoOpForUnknownID() async {
  let bus = EventBus()
  let store = WatcherStore(bus: bus)
  // Must not crash
  await store.remove(id: UUID())
}
```

**Step 2: Run to verify failure**

```sh
swift test --filter WatcherStoreTests
```

Expected: compile error — `remove(id:)` not found on `WatcherStore`.

**Step 3: Implement**

Add to `WatcherStore` (after the `state(for:)` method):

```swift
public func remove(id: WatcherID) {
  runtimes.removeValue(forKey: id)
}
```

**Step 4: Run to verify pass**

```sh
swift test --filter WatcherStoreTests
```

Expected: all tests PASS.

**Step 5: Commit**

Write to `tmp/commit-msg.txt`:
```
feat: add WatcherStore.remove(id:)

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
Claude-Session: SESSION_ID
```

```sh
git add Sources/PixelWatchCore/WatcherStore.swift
```
```sh
git add Tests/PixelWatchCoreTests/WatcherStoreTests.swift
```
```sh
git commit -F tmp/commit-msg.txt
```
```sh
rm tmp/commit-msg.txt
```

---

### Task 2: WatcherOverlayController.remove(watcherID:)

**Files:**
- Modify: `Sources/PixelWatchAppSupport/WatcherOverlayController.swift`
- Modify: `Tests/PixelWatchAppSupportTests/WatcherOverlayControllerTests.swift`

**Step 1: Write the failing test**

Add to `WatcherOverlayControllerTests` (the class is `@MainActor`):

```swift
func testRemoveHidesOverlayAndDropsEntry() {
  let overlay = RecordingOverlayWindow()
  let controller = WatcherOverlayController(
    overlayFactory: { _ in overlay },
    mouseLocationProvider: { CGPoint(x: 220, y: 180) },
    windowSnapshotProvider: StubWindowSnapshotProvider(
      snapshots: [
        WindowSnapshot(
          windowID: 42,
          processID: 99,
          bundleID: "com.example",
          title: "Editor",
          bounds: CGRect(x: 100, y: 100, width: 500, height: 400),
          isVisible: true
        )
      ]
    )
  )

  let session = controller.begin(windowID: 42)
  session.freeze()
  let watcherID = UUID()
  controller.register(watcherID: watcherID, for: session)

  controller.remove(watcherID: watcherID)

  // begin shows true; remove hides it
  XCTAssertEqual(overlay.visibleValues.last, false)
  // sync() no-ops for removed watchers — no new frames recorded
  controller.sync()
  XCTAssertEqual(overlay.frames.count, 1, "sync should not update a removed watcher's overlay")
}

func testRemoveIsNoOpForUnknownID() {
  let controller = WatcherOverlayController(
    overlayFactory: { _ in RecordingOverlayWindow() },
    mouseLocationProvider: { .zero },
    windowSnapshotProvider: StubWindowSnapshotProvider(snapshots: [])
  )
  // Must not crash
  controller.remove(watcherID: UUID())
}
```

**Step 2: Run to verify failure**

```sh
swift test --filter WatcherOverlayControllerTests
```

Expected: compile error — `remove(watcherID:)` not found.

**Step 3: Implement**

Add to `WatcherOverlayController` (after the `update(watcherID:state:)` method):

```swift
/// Hide and discard the overlay for a deleted watcher.
public func remove(watcherID: WatcherID) {
  guard let entry = entries[watcherID] else { return }
  entry.overlay.setVisible(false)
  entries.removeValue(forKey: watcherID)
}
```

**Step 4: Run to verify pass**

```sh
swift test --filter WatcherOverlayControllerTests
```

Expected: all tests PASS.

**Step 5: Commit**

Write to `tmp/commit-msg.txt`:
```
feat: add WatcherOverlayController.remove(watcherID:)

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
Claude-Session: SESSION_ID
```

```sh
git add Sources/PixelWatchAppSupport/WatcherOverlayController.swift
```
```sh
git add Tests/PixelWatchAppSupportTests/WatcherOverlayControllerTests.swift
```
```sh
git commit -F tmp/commit-msg.txt
```
```sh
rm tmp/commit-msg.txt
```

---

### Task 3: FrozenOverlaySession

A minimal `WatcherOverlaySession` that carries a pre-computed `frozenRect`, used by the drag-to-create path so `AppKitConfigureWatcherSheetPresenter` can be reused without modification.

**Files:**
- Create: `Sources/PixelWatchAppSupport/FrozenOverlaySession.swift`
- Create: `Tests/PixelWatchAppSupportTests/FrozenOverlaySessionTests.swift`

**Step 1: Write the failing test**

```swift
// Tests/PixelWatchAppSupportTests/FrozenOverlaySessionTests.swift
import XCTest
@testable import PixelWatchAppSupport

@MainActor
final class FrozenOverlaySessionTests: XCTestCase {
  func testFrozenRectIsReturnedAsIs() {
    let rect = CGRect(x: 10, y: 20, width: 200, height: 150)
    let session = FrozenOverlaySession(frozenRect: rect)
    XCTAssertEqual(session.frozenRect, rect)
  }

  func testNilFrozenRectIsAllowed() {
    let session = FrozenOverlaySession(frozenRect: nil)
    XCTAssertNil(session.frozenRect)
  }

  func testWaitForFreezeReturnsImmediately() async {
    let session = FrozenOverlaySession(frozenRect: .zero)
    // Should complete without hanging
    await session.waitForFreeze()
  }
}
```

**Step 2: Run to verify failure**

```sh
swift test --filter FrozenOverlaySessionTests
```

Expected: compile error — `FrozenOverlaySession` not found.

**Step 3: Implement**

```swift
// Sources/PixelWatchAppSupport/FrozenOverlaySession.swift
import CoreGraphics

/// A pre-frozen WatcherOverlaySession used by the drag-to-create path.
/// Carries the drop-derived screen rect so AppKitConfigureWatcherSheetPresenter
/// can read frozenRect without needing a live overlay session.
@MainActor
public final class FrozenOverlaySession: WatcherOverlaySession {
  public let frozenRect: CGRect?

  public init(frozenRect: CGRect?) {
    self.frozenRect = frozenRect
  }

  public func freeze() {}
  public func cancel() {}
  public func waitForFreeze() async {}
}
```

**Step 4: Run to verify pass**

```sh
swift test --filter FrozenOverlaySessionTests
```

Expected: all tests PASS.

**Step 5: Commit**

Write to `tmp/commit-msg.txt`:
```
feat: add FrozenOverlaySession for drag-to-create path

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
Claude-Session: SESSION_ID
```

```sh
git add Sources/PixelWatchAppSupport/FrozenOverlaySession.swift
```
```sh
git add Tests/PixelWatchAppSupportTests/FrozenOverlaySessionTests.swift
```
```sh
git commit -F tmp/commit-msg.txt
```
```sh
rm tmp/commit-msg.txt
```

---

### Task 4: Gear menu in PopoverGridView

Replace the plain `Button(action: onQuit)` with a `Menu`. The init signature does not change.

**Files:**
- Modify: `Sources/PixelWatchAppSupport/PopoverGridView.swift`

**Step 1: In `PopoverGridView.body`, replace the gear button**

Old (lines ~44–50):
```swift
Button(action: onQuit) {
  Image(systemName: "gearshape")
    .imageScale(.medium)
}
.buttonStyle(.plain)
.padding(8)
```

New:
```swift
Menu {
  Button("Quit PixelWatch", action: onQuit)
} label: {
  Image(systemName: "gearshape").imageScale(.medium)
}
.menuStyle(.borderlessButton)
.fixedSize()
.padding(8)
```

**Step 2: Build**

```sh
swift build
```

Expected: BUILD SUCCEEDED. Fix any Swift 6 errors before continuing.

**Step 3: Commit**

Write to `tmp/commit-msg.txt`:
```
feat: replace gear button with Menu containing Quit item

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
Claude-Session: SESSION_ID
```

```sh
git add Sources/PixelWatchAppSupport/PopoverGridView.swift
```
```sh
git commit -F tmp/commit-msg.txt
```
```sh
rm tmp/commit-msg.txt
```

---

### Task 5: Delete button on thumbnails + delegate wire-up

Adds `onDelete` to `ThumbnailCellView` and `PopoverGridView`, and wires the handler in `PixelWatchMain.swift`. **Both files must be updated in this task** — changing `PopoverGridView.init` breaks the delegate call site.

**Files:**
- Modify: `Sources/PixelWatchAppSupport/PopoverGridView.swift`
- Modify: `Sources/pixelwatch/PixelWatchMain.swift`

**Step 1: Update ThumbnailCellView**

`ThumbnailCellView` gains an `onDelete` closure and a `×` overlay button:

```swift
private struct ThumbnailCellView: View {
  let item: WatcherThumbnailItem
  let onDelete: () -> Void

  var body: some View {
    ZStack(alignment: .topTrailing) {
      VStack(spacing: 0) {
        Text(OverlayAppearance.labelText(for: item.state))
          .font(.system(size: 11))
          .foregroundStyle(.white)
          .frame(maxWidth: .infinity, minHeight: labelHeight, maxHeight: labelHeight)
          .background(Color.black.opacity(0.65))

        ZStack {
          Color.black
          if let nsImage = item.latestFrame?.displayImage {
            Image(nsImage: nsImage)
              .resizable()
              .scaledToFill()
              .clipped()
          }
        }
        .frame(width: cellWidth, height: cellHeight - labelHeight)
        .overlay(
          RoundedRectangle(cornerRadius: 0)
            .strokeBorder(
              Color(nsColor: OverlayAppearance.borderColor(for: item.state)),
              lineWidth: borderWidth
            )
        )
      }

      Button(action: onDelete) {
        Image(systemName: "xmark.circle.fill")
          .foregroundStyle(.white)
          .shadow(radius: 1)
      }
      .buttonStyle(.plain)
      .padding(4)
    }
    .frame(width: cellWidth, height: cellHeight)
    .clipShape(RoundedRectangle(cornerRadius: 4))
  }
}
```

**Step 2: Update PopoverGridView — add onDelete parameter and wire it**

Change the `init` to add `onDelete: @escaping (WatcherID) -> Void` (keep `onAdd` for now — it's removed in Task 7):

```swift
public init(
  model: PopoverModel,
  onAdd: @escaping () -> Void,
  onDelete: @escaping (WatcherID) -> Void,
  onQuit: @escaping () -> Void
) {
  self.model = model
  self.onAdd = onAdd
  self.onDelete = onDelete
  self.onQuit = onQuit
}
```

Add the stored property:
```swift
let onDelete: (WatcherID) -> Void
```

Update the `ForEach` in `body` to pass `onDelete`:
```swift
ForEach(model.items) { item in
  ThumbnailCellView(item: item, onDelete: { onDelete(item.id) })
}
```

**Step 3: Wire `onDelete` in `PixelWatchMain.swift`**

3a. Add `handleDeleteWatcher(id:)` method to `PixelWatchAppDelegate`:

```swift
private func handleDeleteWatcher(id: WatcherID) {
  watchers.removeAll { $0.id == id }
  do {
    try persistence.save(watchers)
  } catch {
    NSLog("Failed to save after delete: %@", error.localizedDescription)
  }
  Task {
    await store.remove(id: id)
    await MainActor.run {
      overlayController.remove(watcherID: id)
    }
    await refreshPopover()
  }
}
```

3b. Update the `popoverController` lazy var to pass `onDelete`:

```swift
private lazy var popoverController: NSHostingController<PopoverGridView> = {
  NSHostingController(rootView: PopoverGridView(
    model: popoverModel,
    onAdd: { [weak self] in self?.newWatcherClicked(nil) },
    onDelete: { [weak self] id in self?.handleDeleteWatcher(id: id) },
    onQuit: { NSApp.terminate(nil) }
  ))
}()
```

**Step 4: Build**

```sh
swift build
```

Expected: BUILD SUCCEEDED.

**Step 5: Manual smoke test**

```sh
.build/debug/pixelwatch &
```

- Open the popover.
- If watchers exist: each cell should show a white `×` at top-right. Clicking it should remove the cell immediately, with no confirmation.
- Check `~/Library/Application\ Support/PixelWatch/watchers.json` — deleted watcher should be gone.
- Kill: `pkill pixelwatch`

**Step 6: Commit**

Write to `tmp/commit-msg.txt`:
```
feat: add delete button to watcher thumbnails

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
Claude-Session: SESSION_ID
```

```sh
git add Sources/PixelWatchAppSupport/PopoverGridView.swift
```
```sh
git add Sources/pixelwatch/PixelWatchMain.swift
```
```sh
git commit -F tmp/commit-msg.txt
```
```sh
rm tmp/commit-msg.txt
```

---

### Task 6: DragSourceCellView

A new `NSViewRepresentable` that renders the `+` square visually, captures mouse drag events, shows a floating panel during the drag, and calls `onDrop(screenPoint:)` when the mouse is released.

**Files:**
- Create: `Sources/PixelWatchAppSupport/DragSourceCellView.swift`

**Step 1: Write the file**

```swift
// Sources/PixelWatchAppSupport/DragSourceCellView.swift
import AppKit
import SwiftUI

private let dragThreshold: CGFloat = 5
private let dropSquareSize = CGSize(width: 120, height: 96)

// MARK: - NSViewRepresentable entry point

struct DragSourceCellView: NSViewRepresentable {
  let onDrop: @MainActor (CGPoint) -> Void
  let onDragStarted: @MainActor () -> Void

  func makeNSView(context: Context) -> DragSourceNSView {
    let v = DragSourceNSView()
    v.onDrop = onDrop
    v.onDragStarted = onDragStarted
    return v
  }

  func updateNSView(_ nsView: DragSourceNSView, context: Context) {
    nsView.onDrop = onDrop
    nsView.onDragStarted = onDragStarted
  }
}

// MARK: - AppKit drag source view

/// Transparent NSView that handles mouse tracking. The visible "+" square is
/// drawn by NSView.draw(_:) so no SwiftUI overlay is needed.
@MainActor
final class DragSourceNSView: NSView {
  var onDrop: @MainActor (CGPoint) -> Void = { _ in }
  var onDragStarted: @MainActor () -> Void = {}

  private var dragStartPoint: CGPoint?
  private var isDragging = false
  private var floatingPanel: NSPanel?
  private var trackingTimer: Timer?
  private var mouseUpMonitor: Any?

  override var acceptsFirstResponder: Bool { true }

  // MARK: Drawing

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    let inset = bounds.insetBy(dx: 2, dy: 2)
    let path = NSBezierPath(roundedRect: inset, xRadius: 4, yRadius: 4)
    NSColor.secondaryLabelColor.setStroke()
    path.lineWidth = 3
    path.stroke()

    let attrs: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 28),
      .foregroundColor: NSColor.secondaryLabelColor,
    ]
    let str = NSAttributedString(string: "+", attributes: attrs)
    let size = str.size()
    str.draw(
      at: NSPoint(
        x: (bounds.width - size.width) / 2,
        y: (bounds.height - size.height) / 2
      )
    )
  }

  // MARK: Mouse events

  override func mouseDown(with event: NSEvent) {
    dragStartPoint = convert(event.locationInWindow, from: nil)
    isDragging = false
  }

  override func mouseDragged(with event: NSEvent) {
    guard let start = dragStartPoint, !isDragging else { return }
    let current = convert(event.locationInWindow, from: nil)
    let dx = current.x - start.x
    let dy = current.y - start.y
    guard sqrt(dx * dx + dy * dy) >= dragThreshold else { return }
    startDrag()
  }

  override func mouseUp(with event: NSEvent) {
    if isDragging {
      endDrag(at: NSEvent.mouseLocation)
    }
    dragStartPoint = nil
  }

  // MARK: Drag lifecycle

  private func startDrag() {
    isDragging = true
    onDragStarted()
    showFloatingPanel(at: NSEvent.mouseLocation)

    trackingTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, self.isDragging else { return }
        self.floatingPanel?.setFrameOrigin(
          NSPoint(
            x: NSEvent.mouseLocation.x - dropSquareSize.width / 2,
            y: NSEvent.mouseLocation.y - dropSquareSize.height / 2
          )
        )
      }
    }

    mouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, self.isDragging else { return }
        self.endDrag(at: NSEvent.mouseLocation)
      }
    }
  }

  private func endDrag(at screenPoint: CGPoint) {
    guard isDragging else { return }
    isDragging = false
    dragStartPoint = nil

    trackingTimer?.invalidate()
    trackingTimer = nil

    if let monitor = mouseUpMonitor {
      NSEvent.removeMonitor(monitor)
      mouseUpMonitor = nil
    }

    floatingPanel?.close()
    floatingPanel = nil

    onDrop(screenPoint)
  }

  private func showFloatingPanel(at origin: CGPoint) {
    let panel = NSPanel(
      contentRect: NSRect(
        x: origin.x - dropSquareSize.width / 2,
        y: origin.y - dropSquareSize.height / 2,
        width: dropSquareSize.width,
        height: dropSquareSize.height
      ),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.level = .floating
    panel.ignoresMouseEvents = true
    panel.isReleasedWhenClosed = false

    // Draw the same "+" visual inside the floating panel using a simple NSView
    let contentView = DragFloatVisualView(frame: NSRect(origin: .zero, size: dropSquareSize))
    panel.contentView = contentView
    panel.orderFront(nil)
    floatingPanel = panel
  }
}

// MARK: - Floating panel visual

private final class DragFloatVisualView: NSView {
  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    let inset = bounds.insetBy(dx: 2, dy: 2)
    let path = NSBezierPath(roundedRect: inset, xRadius: 4, yRadius: 4)
    NSColor.secondaryLabelColor.withAlphaComponent(0.85).setStroke()
    path.lineWidth = 3
    path.stroke()

    let attrs: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 28),
      .foregroundColor: NSColor.secondaryLabelColor.withAlphaComponent(0.85),
    ]
    let str = NSAttributedString(string: "+", attributes: attrs)
    let size = str.size()
    str.draw(
      at: NSPoint(
        x: (bounds.width - size.width) / 2,
        y: (bounds.height - size.height) / 2
      )
    )
  }
}
```

**Step 2: Build**

```sh
swift build
```

Expected: BUILD SUCCEEDED. Fix any Swift 6 concurrency errors before continuing.

**Step 3: Commit**

Write to `tmp/commit-msg.txt`:
```
feat: add DragSourceCellView for drag-to-create flow

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
Claude-Session: SESSION_ID
```

```sh
git add Sources/PixelWatchAppSupport/DragSourceCellView.swift
```
```sh
git commit -F tmp/commit-msg.txt
```
```sh
rm tmp/commit-msg.txt
```

---

### Task 7: Wire drag-to-create in PopoverGridView + delegate

Replace `AddCellView` with `DragSourceCellView` in the grid, swap `onAdd` for `onDrop` in the init, and implement `handleDrop(at:)` in the delegate. **Both files must be updated in this task.**

**Files:**
- Modify: `Sources/PixelWatchAppSupport/PopoverGridView.swift`
- Modify: `Sources/pixelwatch/PixelWatchMain.swift`

**Step 1: Update PopoverGridView**

1a. Remove the `onAdd` property and replace with `onDrop: (CGPoint) -> Void`:

```swift
public struct PopoverGridView: View {
  @State var model: PopoverModel
  let onDelete: (WatcherID) -> Void
  let onDrop: (CGPoint) -> Void
  let onQuit: () -> Void

  public init(
    model: PopoverModel,
    onDelete: @escaping (WatcherID) -> Void,
    onDrop: @escaping (CGPoint) -> Void,
    onQuit: @escaping () -> Void
  ) {
    self.model = model
    self.onDelete = onDelete
    self.onDrop = onDrop
    self.onQuit = onQuit
  }
  // ...
}
```

1b. In `body`, replace `AddCellView(onAdd: onAdd)` with `DragSourceCellView`:

```swift
DragSourceCellView(
  onDrop: onDrop,
  onDragStarted: {}
)
.frame(width: cellWidth, height: cellHeight)
```

Note: `onDragStarted` is wired in Step 2 via the delegate — for now pass an empty closure.

1c. Delete the `AddCellView` struct entirely (it's replaced by `DragSourceCellView`).

**Step 2: Update PixelWatchMain.swift**

2a. Add `handleDrop(at:)` method to `PixelWatchAppDelegate`:

```swift
private func handleDrop(at appKitPoint: CGPoint) {
  // NSEvent.mouseLocation uses AppKit bottom-left origin.
  // CGWindowListCopyWindowInfo bounds use CoreGraphics top-left origin.
  // Flip Y before comparing against window bounds.
  let screenHeight = NSScreen.main?.frame.height ?? 0
  let cgPoint = CGPoint(x: appKitPoint.x, y: screenHeight - appKitPoint.y)

  let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
  guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
    return
  }

  let ownPID = ProcessInfo.processInfo.processIdentifier

  // CGWindowList is ordered front-to-back; take the first non-PixelWatch window
  // whose bounds contain the drop point.
  var targetInfo: [String: Any]?
  for info in list {
    guard
      let pid = CGWindowDictParser.processIDValue(info[String(kCGWindowOwnerPID)]),
      pid != ownPID,
      let bounds = CGWindowDictParser.rectValue(info[String(kCGWindowBounds)]),
      bounds.contains(cgPoint)
    else { continue }
    targetInfo = info
    break
  }

  guard
    let info = targetInfo,
    let bounds = CGWindowDictParser.rectValue(info[String(kCGWindowBounds)]),
    let windowID = CGWindowDictParser.uint32Value(info[String(kCGWindowNumber)]),
    let pid = CGWindowDictParser.processIDValue(info[String(kCGWindowOwnerPID)])
  else {
    let alert = NSAlert()
    alert.messageText = "PixelWatch could not find a window at that location."
    alert.runModal()
    return
  }

  let title = (info[String(kCGWindowName)] as? String) ?? ""
  let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""

  let windowSnapshot = WindowSnapshot(
    windowID: windowID,
    processID: pid,
    bundleID: bundleID,
    title: title,
    bounds: bounds,
    isVisible: true
  )

  let dropSize = CGSize(width: 200, height: 150)
  let screenRect = CGRect(
    x: cgPoint.x - dropSize.width / 2,
    y: cgPoint.y - dropSize.height / 2,
    width: dropSize.width,
    height: dropSize.height
  )
  let rect = windowRelativeRect(fromScreen: screenRect, windowBounds: bounds)

  let draft = WatcherDraft(
    window: windowSnapshot,
    name: title.isEmpty ? bundleID : title,
    sensitivity: 0.5,
    command: "",
    armed: false
  )

  let session = FrozenOverlaySession(frozenRect: screenRect)
  let presenter = AppKitConfigureWatcherSheetPresenter()

  Task {
    guard let watcher = await presenter.present(draft: draft, overlay: session) else { return }
    handleWatcherCreatedFromDrag(watcher, windowID: windowID)
  }
}

private func handleWatcherCreatedFromDrag(_ watcher: Watcher, windowID: UInt32) {
  watchers.append(watcher)
  do {
    try persistence.save(watchers)
  } catch {
    NSLog("Failed to save watcher: %@", error.localizedDescription)
  }
  Task {
    await store.add(watcher)
    if watcher.armed {
      await WatcherArmService.arm(watcherID: watcher.id, bus: bus, store: store)
    }
    await MainActor.run {
      overlayController.restore(
        watcherID: watcher.id,
        windowID: windowID,
        windowRelativeRect: watcher.rect,
        state: watcher.armed ? .armed : .idle
      )
    }
    await refreshPopover()
  }
}
```

2b. Update `popoverController` lazy var to pass `onDrop` and wire `onDragStarted` to change popover behavior:

```swift
private lazy var popoverController: NSHostingController<PopoverGridView> = {
  NSHostingController(rootView: PopoverGridView(
    model: popoverModel,
    onDelete: { [weak self] id in self?.handleDeleteWatcher(id: id) },
    onDrop: { [weak self] point in self?.handleDrop(at: point) },
    onQuit: { NSApp.terminate(nil) }
  ))
}()
```

2c. Update `DragSourceCellView` in `PopoverGridView.body` to wire `onDragStarted` — open `PopoverGridView.swift` and change the `DragSourceCellView` call to:

```swift
DragSourceCellView(
  onDrop: onDrop,
  onDragStarted: { [weak popover] in
    popover?.behavior = .applicationDefined
  }
)
.frame(width: cellWidth, height: cellHeight)
```

However `PopoverGridView` doesn't have a reference to the `NSPopover`. The cleanest approach: add `onDragStarted: () -> Void` to `PopoverGridView` as a stored property and pass it from the delegate. Update accordingly:

`PopoverGridView` gains:
```swift
let onDragStarted: () -> Void
```

Updated init:
```swift
public init(
  model: PopoverModel,
  onDelete: @escaping (WatcherID) -> Void,
  onDrop: @escaping (CGPoint) -> Void,
  onDragStarted: @escaping () -> Void = {},
  onQuit: @escaping () -> Void
) { ... }
```

The `popoverController` lazy var in the delegate passes:
```swift
onDragStarted: { [weak self] in
  self?.popover.behavior = .applicationDefined
},
```

And after `endDrag` in `DragSourceNSView` calls `onDrop`, the delegate's `handleDrop` method closes the popover. Add this at the start of `handleDrop`:
```swift
popover.behavior = .transient
popover.performClose(nil)
```

**Step 3: Build**

```sh
swift build
```

Expected: BUILD SUCCEEDED. Fix any Swift 6 errors before continuing.

**Step 4: Run all tests**

```sh
swift test
```

Expected: all tests PASS.

**Step 5: Manual end-to-end test**

```sh
.build/debug/pixelwatch &
```

1. Open the popover — `+` cell is visible with a dashed border and `+` glyph.
2. Click the gear icon — a menu appears with "Quit PixelWatch".
3. Drag from the `+` cell onto any other open window:
   - The `+` square should follow the cursor as a floating panel.
   - The popover should stay open during the drag.
   - On release, the popover closes and the "New Watcher" configure sheet appears as a standalone floating panel.
4. Fill in a name and click "Save" — the watcher appears in the grid.
5. Click the `×` on that cell — watcher disappears immediately.
6. Kill: `pkill pixelwatch`

**Step 6: Commit**

Write to `tmp/commit-msg.txt`:
```
feat: replace + button with drag-to-create flow

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
Claude-Session: SESSION_ID
```

```sh
git add Sources/PixelWatchAppSupport/PopoverGridView.swift
```
```sh
git add Sources/pixelwatch/PixelWatchMain.swift
```
```sh
git commit -F tmp/commit-msg.txt
```
```sh
rm tmp/commit-msg.txt
```
