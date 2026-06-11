# Popover Thumbnail Grid — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace the `NSMenu` on the menu-bar status item with an `NSPopover` containing a SwiftUI grid of watcher thumbnails, as specified in `2026-06-11-popover-grid-design.md`.

**Architecture:** Three new files in `PixelWatchAppSupport` handle the data model, the `PixelBuffer→NSImage` conversion, and the SwiftUI grid view. The app delegate in `pixelwatch` is the only file modified — `refreshMenu()` is replaced by an `async refreshPopover()` that queries `WatcherStore` for snapshots.

**Tech Stack:** Swift 6, SwiftUI (`@Observable`, `LazyVGrid`, `NSHostingController`), AppKit (`NSPopover`, `NSMenu`), Accelerate (`vvpowsf`), XCTest.

---

### Task 1: Data model — WatcherThumbnailItem + PopoverModel

**Files:**
- Create: `Sources/PixelWatchAppSupport/PopoverModel.swift`
- Create: `Tests/PixelWatchAppSupportTests/PopoverModelTests.swift`

**Step 1: Write the failing test**

```swift
// Tests/PixelWatchAppSupportTests/PopoverModelTests.swift
import XCTest
@testable import PixelWatchAppSupport

@MainActor
final class PopoverModelTests: XCTestCase {
  func testStartsEmpty() {
    let model = PopoverModel()
    XCTAssertTrue(model.items.isEmpty)
  }

  func testItemsAreMutable() {
    let model = PopoverModel()
    let item = WatcherThumbnailItem(
      id: UUID(),
      name: "Test",
      state: .idle,
      latestFrame: nil
    )
    model.items = [item]
    XCTAssertEqual(model.items.count, 1)
    XCTAssertEqual(model.items[0].name, "Test")
  }

  func testWatcherThumbnailItemIsIdentifiableById() {
    let id = UUID()
    let a = WatcherThumbnailItem(id: id, name: "A", state: .armed, latestFrame: nil)
    let b = WatcherThumbnailItem(id: id, name: "B", state: .idle, latestFrame: nil)
    XCTAssertEqual(a.id, b.id)
  }
}
```

**Step 2: Run test to verify it fails**

```sh
swift test --filter PopoverModelTests
```

Expected: compile error — `PopoverModel` and `WatcherThumbnailItem` not found.

**Step 3: Write the implementation**

```swift
// Sources/PixelWatchAppSupport/PopoverModel.swift
import Observation
import PixelWatchCore

public struct WatcherThumbnailItem: Identifiable, Sendable {
  public let id: WatcherID
  public let name: String
  public let state: WatcherState
  public let latestFrame: PixelBuffer?

  public init(id: WatcherID, name: String, state: WatcherState, latestFrame: PixelBuffer?) {
    self.id = id
    self.name = name
    self.state = state
    self.latestFrame = latestFrame
  }
}

@Observable @MainActor
public final class PopoverModel {
  public var items: [WatcherThumbnailItem] = []

  public init() {}
}
```

**Step 4: Run test to verify it passes**

```sh
swift test --filter PopoverModelTests
```

Expected: all 3 tests PASS.

**Step 5: Commit**

Write to `tmp/commit-msg.txt`:
```
feat: add WatcherThumbnailItem and PopoverModel data layer

Claude-Session: SESSION_ID
Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
```

```sh
git add Sources/PixelWatchAppSupport/PopoverModel.swift
git add Tests/PixelWatchAppSupportTests/PopoverModelTests.swift
git commit -F tmp/commit-msg.txt
rm tmp/commit-msg.txt
```

---

### Task 2: PixelBuffer → NSImage conversion

**Files:**
- Create: `Sources/PixelWatchAppSupport/PixelBufferImage.swift`
- Create: `Tests/PixelWatchAppSupportTests/PixelBufferImageTests.swift`

**Background:** `PixelBuffer.linearRGB` stores gamma-decoded linear-light floats (3 × Float per pixel). To produce a display-ready `NSImage`:
1. Raise each channel to `1/2.2` (re-apply sRGB gamma) using `vvpowsf`.
2. Clamp to `[0, 1]` with `vDSP_vclip`.
3. Pack as RGBA bytes (alpha = 255).
4. Create a `CGImage` via `CGContext` in sRGB.
5. Wrap in `NSImage`.

`vvpowsf(result, scalar_exponent_ptr, base_array, count)` computes `result[i] = base[i]^scalar`. This is the same call pattern used in `Diff.makeBuffer` to go the other direction (`^2.2`); here we use `^(1/2.2)`.

**Step 1: Write the failing tests**

```swift
// Tests/PixelWatchAppSupportTests/PixelBufferImageTests.swift
import AppKit
import XCTest
@testable import PixelWatchAppSupport
@testable import PixelWatchCore

final class PixelBufferImageTests: XCTestCase {
  func testEmptyBufferReturnsNil() {
    let buf = PixelBuffer(width: 2, height: 2, linearRGB: [])
    XCTAssertNil(buf.displayImage)
  }

  func testZeroDimensionReturnsNil() {
    let buf = PixelBuffer(width: 0, height: 0, linearRGB: [])
    XCTAssertNil(buf.displayImage)
  }

  func testImageDimensionsMatchBuffer() {
    // 2×1 solid black (linear 0,0,0)
    let buf = PixelBuffer(width: 2, height: 1, linearRGB: [Float](repeating: 0, count: 6))
    let img = buf.displayImage
    XCTAssertNotNil(img)
    XCTAssertEqual(img?.size.width, 2)
    XCTAssertEqual(img?.size.height, 1)
  }

  func testFullBrightLinearRGBProducesWhitePixel() {
    // linear 1.0 → sRGB 1.0 → byte 255
    let buf = PixelBuffer(width: 1, height: 1, linearRGB: [1.0, 1.0, 1.0])
    guard let img = buf.displayImage,
          let cgImg = img.cgImage(forProposedRect: nil, context: nil, hints: nil)
    else { XCTFail("no image"); return }

    var rgba = [UInt8](repeating: 0, count: 4)
    let ctx = CGContext(
      data: &rgba, width: 1, height: 1, bitsPerComponent: 8,
      bytesPerRow: 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    )!
    ctx.draw(cgImg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    // Allow ±2 for rounding
    XCTAssertEqual(Int(rgba[0]), 255, accuracy: 2)
    XCTAssertEqual(Int(rgba[1]), 255, accuracy: 2)
    XCTAssertEqual(Int(rgba[2]), 255, accuracy: 2)
  }
}
```

**Step 2: Run to verify failure**

```sh
swift test --filter PixelBufferImageTests
```

Expected: compile error — `displayImage` not found on `PixelBuffer`.

**Step 3: Write the implementation**

```swift
// Sources/PixelWatchAppSupport/PixelBufferImage.swift
import Accelerate
import AppKit
import PixelWatchCore

extension PixelBuffer {
  /// Converts the linear-light float buffer back to a display-ready NSImage.
  /// Returns nil if the buffer has no pixel data.
  public var displayImage: NSImage? {
    guard !linearRGB.isEmpty, width > 0, height > 0 else { return nil }
    let pixelCount = width * height

    // Step 1: apply sRGB gamma (linear -> display)
    var exponent: Float = 1.0 / 2.2
    var srgb = [Float](repeating: 0, count: pixelCount * 3)
    var n = Int32(pixelCount * 3)
    vvpowsf(&srgb, &exponent, linearRGB, &n)

    // Step 2: clamp to [0, 1]
    var lo: Float = 0, hi: Float = 1
    vDSP_vclip(&srgb, 1, &lo, &hi, &srgb, 1, vDSP_Length(pixelCount * 3))

    // Step 3: pack as RGBA bytes (alpha = 255)
    var rgba = [UInt8](repeating: 255, count: pixelCount * 4)
    for i in 0..<pixelCount {
      rgba[i * 4 + 0] = UInt8(srgb[i * 3 + 0] * 255)
      rgba[i * 4 + 1] = UInt8(srgb[i * 3 + 1] * 255)
      rgba[i * 4 + 2] = UInt8(srgb[i * 3 + 2] * 255)
    }

    // Step 4: create CGImage
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let provider = CGDataProvider(data: Data(rgba) as CFData),
          let cgImage = CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider,
            decode: nil, shouldInterpolate: false,
            intent: .defaultIntent
          )
    else { return nil }

    return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
  }
}
```

**Step 4: Run to verify tests pass**

```sh
swift test --filter PixelBufferImageTests
```

Expected: all 4 tests PASS.

**Step 5: Commit**

Write to `tmp/commit-msg.txt`:
```
feat: add PixelBuffer.displayImage for gamma-decode and NSImage wrapping

Claude-Session: SESSION_ID
Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
```

```sh
git add Sources/PixelWatchAppSupport/PixelBufferImage.swift
git add Tests/PixelWatchAppSupportTests/PixelBufferImageTests.swift
git commit -F tmp/commit-msg.txt
rm tmp/commit-msg.txt
```

---

### Task 3: SwiftUI PopoverGridView

**Files:**
- Create: `Sources/PixelWatchAppSupport/PopoverGridView.swift`

No unit tests for pure SwiftUI views. Verify via build in step 4.

**Step 1: Write the view**

Cell size constants from the design doc: 120 × 96 pt total, 18 pt label strip, 78 pt image area, 3 pt border, 10 pt grid spacing, 380 pt popover width.

```swift
// Sources/PixelWatchAppSupport/PopoverGridView.swift
import AppKit
import SwiftUI

private let cellWidth: CGFloat = 120
private let cellHeight: CGFloat = 96
private let labelHeight: CGFloat = 18
private let borderWidth: CGFloat = 3
private let gridSpacing: CGFloat = 10

public struct PopoverGridView: View {
  @State var model: PopoverModel
  let onAdd: () -> Void
  let onQuit: () -> Void

  public init(model: PopoverModel, onAdd: @escaping () -> Void, onQuit: @escaping () -> Void) {
    self.model = model
    self.onAdd = onAdd
    self.onQuit = onQuit
  }

  public var body: some View {
    VStack(spacing: 0) {
      ScrollView {
        if model.items.isEmpty {
          Text("No watchers yet")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 80)
            .padding()
        } else {
          LazyVGrid(
            columns: [GridItem(.adaptive(minimum: cellWidth), spacing: gridSpacing)],
            spacing: gridSpacing
          ) {
            ForEach(model.items) { item in
              ThumbnailCellView(item: item)
            }
            AddCellView(onAdd: onAdd)
          }
          .padding(gridSpacing)
        }
      }

      Divider()

      HStack {
        Spacer()
        Button(action: showQuitMenu) {
          Image(systemName: "gearshape")
            .imageScale(.medium)
        }
        .buttonStyle(.plain)
        .padding(8)
      }
    }
    .frame(width: 380)
  }

  private func showQuitMenu() {
    let menu = NSMenu()
    menu.addItem(NSMenuItem(
      title: "Quit PixelWatch",
      action: #selector(NSApplication.terminate(_:)),
      keyEquivalent: "q"
    ))
    // Pop the menu next to the gear button's event
    if let event = NSApp.currentEvent {
      NSMenu.popUpContextMenu(menu, with: event, for: NSApp.keyWindow?.contentView ?? NSView())
    }
  }
}

private struct ThumbnailCellView: View {
  let item: WatcherThumbnailItem

  var body: some View {
    VStack(spacing: 0) {
      // Label strip
      Text(OverlayAppearance.labelText(for: item.state))
        .font(.system(size: 11))
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, minHeight: labelHeight, maxHeight: labelHeight)
        .background(Color.black.opacity(0.65))

      // Image area with border
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
    .frame(width: cellWidth, height: cellHeight)
    .clipShape(RoundedRectangle(cornerRadius: 4))
  }
}

private struct AddCellView: View {
  let onAdd: () -> Void

  var body: some View {
    Button(action: onAdd) {
      ZStack {
        RoundedRectangle(cornerRadius: 4)
          .strokeBorder(Color.secondary, lineWidth: borderWidth)
        Text("+")
          .font(.system(size: 28))
          .foregroundStyle(.secondary)
      }
      .frame(width: cellWidth, height: cellHeight)
    }
    .buttonStyle(.plain)
  }
}
```

**Step 2: Build to verify it compiles**

```sh
swift build
```

Expected: BUILD SUCCEEDED. Fix any Swift 6 Sendable or concurrency errors before proceeding.

**Note on `@State var model: PopoverModel`:** Because `PopoverModel` is `@Observable`, storing it as `@State` lets SwiftUI track mutations. The delegate holds the authoritative instance and passes it in; SwiftUI's `@State` here just holds the reference — it does not copy the object.

**Step 3: Commit**

Write to `tmp/commit-msg.txt`:
```
feat: add SwiftUI PopoverGridView with thumbnail cells and add button

Claude-Session: SESSION_ID
Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
```

```sh
git add Sources/PixelWatchAppSupport/PopoverGridView.swift
git commit -F tmp/commit-msg.txt
rm tmp/commit-msg.txt
```

---

### Task 4: Wire popover into the app delegate

**Files:**
- Modify: `Sources/pixelwatch/PixelWatchMain.swift`

**Step 1: Read the current delegate** before editing (required by tooling).

**Step 2: Add the popover properties and create them at launch**

Replace the `statusItem` setup block (around `applicationDidFinishLaunching`) with popover-based setup. Changes are additive + two method replacements; nothing else in the file changes.

**Properties to add** to `PixelWatchAppDelegate`:

```swift
private let popoverModel = PopoverModel()
private lazy var popoverController: NSHostingController<PopoverGridView> = {
    NSHostingController(rootView: PopoverGridView(
        model: popoverModel,
        onAdd: { [weak self] in self?.newWatcherClicked(nil) },
        onQuit: { NSApp.terminate(nil) }
    ))
}()
private lazy var popover: NSPopover = {
    let p = NSPopover()
    p.contentViewController = popoverController
    p.behavior = .transient
    return p
}()
```

**Remove** the `lastEventDescription` property (no longer needed).

**Replace** the status item setup in `applicationDidFinishLaunching`:

Old:
```swift
statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
statusItem?.button?.title = "PixelWatch"
```

New:
```swift
statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
statusItem?.button?.title = "PW"
statusItem?.button?.action = #selector(togglePopover(_:))
statusItem?.button?.target = self
```

**Replace** `refreshMenu()` with `refreshPopover()`:

Old `refreshMenu()` body:
```swift
private func refreshMenu() {
    let menu = NSMenu()
    // ... build NSMenu ...
    statusItem?.menu = menu
}
```

New `refreshPopover()`:
```swift
private func refreshPopover() async {
    var items: [WatcherThumbnailItem] = []
    for watcher in watchers {
        let snap = await store.snapshot(for: watcher.id)
        items.append(WatcherThumbnailItem(
            id: watcher.id,
            name: watcher.name,
            state: snap?.state ?? .idle,
            latestFrame: snap?.latestFrame
        ))
    }
    popoverModel.items = items
}
```

**Add** the toggle action:
```swift
@objc private func togglePopover(_ sender: AnyObject?) {
    guard let button = statusItem?.button else { return }
    if popover.isShown {
        popover.performClose(sender)
    } else {
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }
}
```

**Update all callers** of `refreshMenu()` to `Task { await self.refreshPopover() }`:

| Location | Old | New |
|---|---|---|
| `applicationDidFinishLaunching` | `refreshMenu()` | `Task { await self.refreshPopover() }` |
| `startRuntime()` — `await MainActor.run` | `refreshMenu()` | `await self.refreshPopover()` (already in async context) |
| `startEventMonitor()` — `await MainActor.run` | `refreshMenu()` | `await self.refreshPopover()` |
| `handleWatcherCreated` — end of `Task` | `await MainActor.run { refreshMenu() }` | `await refreshPopover()` |

Also **remove** `describe(_:)` and `format(_:)` static helpers (were only used by `refreshMenu()`), and the `lastEventDescription` property.

**Step 3: Build**

```sh
swift build
```

Expected: BUILD SUCCEEDED. Fix concurrency/Sendable errors as they arise.

**Step 4: Run and verify manually**

```sh
.build/debug/pixelwatch &
```

Open the menu bar, click "PW":
- Popover appears below the status item.
- If no watchers: shows "No watchers yet" placeholder text.
- If watchers exist (loaded from `~/Library/Application Support/PixelWatch/watchers.json`): each cell shows state label, frame (or black), and state-colored border.
- "+" cell triggers new-watcher flow.
- Gear button → "Quit PixelWatch" menu item.
- Clicking outside dismisses the popover.
- Clicking "PW" again while open closes the popover.

Kill the process after manual verification: `pkill pixelwatch`

**Step 5: Commit**

Write to `tmp/commit-msg.txt`:
```
feat: replace NSMenu with NSPopover + SwiftUI thumbnail grid

Claude-Session: SESSION_ID
Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
```

```sh
git add Sources/pixelwatch/PixelWatchMain.swift
git commit -F tmp/commit-msg.txt
rm tmp/commit-msg.txt
```

---

## Summary

| Task | Files | Tests |
|---|---|---|
| 1. Data model | `PopoverModel.swift` | `PopoverModelTests.swift` |
| 2. PixelBuffer→NSImage | `PixelBufferImage.swift` | `PixelBufferImageTests.swift` |
| 3. SwiftUI grid view | `PopoverGridView.swift` | build-only |
| 4. App delegate wiring | `PixelWatchMain.swift` | manual run |
