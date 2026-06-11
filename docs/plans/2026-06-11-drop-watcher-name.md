# Drop Watcher `name` Field Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Remove the `name` field from `Watcher` (and all supporting types), relying on `titleMatch.literalValue` for human-readable identification in logs and error messages.

**Architecture:** `WATCH_NAME` hook env var is already redundant — `WATCH_WINDOW_APP` and `WATCH_WINDOW_TITLE` carry the same info. `TitleMatch.literalValue` (currently a private extension in `Stages.swift`) becomes a public property on `TitleMatch` in `Models.swift` so other callers can use it. All `name` params are deleted from `Watcher`, `WatcherDraft`, `WatcherThumbnailItem`, and the configure sheet. Old `watchers.json` files decode cleanly — Swift's `JSONDecoder` silently ignores unknown keys.

**Tech Stack:** Swift 6, SwiftPM, XCTest. No external deps.

---

### Task 1: Promote `TitleMatch.literalValue` to public API

**Files:**
- Modify: `Sources/PixelWatchCore/Models.swift`
- Modify: `Sources/PixelWatchCore/Stages.swift`

The private extension in `Stages.swift` needs to move to `Models.swift` so `WatcherArmService` (and any future caller) can use it without importing internals.

**Step 1: Write a failing test**

In `Tests/PixelWatchCoreTests/TitleMatchTests.swift` (create new file):

```swift
import XCTest
@testable import PixelWatchCore

final class TitleMatchTests: XCTestCase {
  func testLiteralValueExtractsInnerString() {
    XCTAssertEqual(TitleMatch.exact("Xcode").literalValue, "Xcode")
    XCTAssertEqual(TitleMatch.contains("Build").literalValue, "Build")
    XCTAssertEqual(TitleMatch.regex("^Build.*").literalValue, "^Build.*")
  }
}
```

**Step 2: Run test to verify it fails**

```
swift test --filter PixelWatchCoreTests.TitleMatchTests
```
Expected: compile error — `literalValue` is not accessible (it's `private` in `Stages.swift`).

**Step 3: Move `literalValue` to `Models.swift` as a public extension**

Append to `Sources/PixelWatchCore/Models.swift`:

```swift
public extension TitleMatch {
  var literalValue: String {
    switch self {
    case let .exact(value), let .contains(value), let .regex(value):
      value
    }
  }
}
```

Then delete the private extension block at the bottom of `Sources/PixelWatchCore/Stages.swift` (lines ~233–240):

```swift
// DELETE this block:
private extension TitleMatch {
  var literalValue: String {
    switch self {
    case let .exact(value), let .contains(value), let .regex(value):
      value
    }
  }
}
```

**Step 4: Run test to verify it passes**

```
swift test --filter PixelWatchCoreTests.TitleMatchTests
```
Expected: PASS

**Step 5: Commit**

Write to `tmp/commit-msg.txt`:
```
refactor: promote TitleMatch.literalValue to public API in Models

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
Claude-Session: f30bc643-dc00-4b1b-9ae6-49154b9a3d3b
```
Stage and commit:
```
git add Sources/PixelWatchCore/Models.swift Sources/PixelWatchCore/Stages.swift Tests/PixelWatchCoreTests/TitleMatchTests.swift
git commit -F tmp/commit-msg.txt
rm tmp/commit-msg.txt
```

---

### Task 2: Remove `name` from `Watcher` model and Core call sites

**Files:**
- Modify: `Sources/PixelWatchCore/Models.swift`
- Modify: `Sources/PixelWatchCore/Stages.swift`
- Modify: `Sources/PixelWatchCore/WatcherArmService.swift`
- Modify: `Tests/PixelWatchCoreTests/TestSupport.swift`
- Modify: `Tests/PixelWatchCoreTests/PersistenceTests.swift`
- Modify: `Tests/PixelWatchCoreTests/HookStageTests.swift`

**Step 1: Delete `name` from `Watcher` in `Models.swift`**

Remove `public var name: String` and the `name: String` parameter from `init`. The struct becomes:

```swift
public struct Watcher: Codable, Equatable, Sendable {
  public let id: WatcherID
  public var target: WindowBinding
  public var rect: CGRect
  public var sensitivity: Double
  public var tickIntervalSeconds: Double
  public var command: String
  public var armed: Bool

  public init(
    id: WatcherID,
    target: WindowBinding,
    rect: CGRect,
    sensitivity: Double,
    tickIntervalSeconds: Double,
    command: String,
    armed: Bool
  ) {
    self.id = id
    self.target = target
    self.rect = rect
    self.sensitivity = sensitivity
    self.tickIntervalSeconds = tickIntervalSeconds
    self.command = command
    self.armed = armed
  }
}
```

**Step 2: Remove `WATCH_NAME` from `HookEnvironment.make` in `Stages.swift`**

Delete the `"WATCH_NAME": watcher.name,` line from the dictionary in `HookEnvironment.make` (~line 201).

**Step 3: Update error message in `WatcherArmService.swift`**

Change the error message from:
```swift
message: "Window not found for watcher '\(watcher.name)'"
```
to:
```swift
message: "Window not found for watcher '\(watcher.target.titleMatch.literalValue)' (\(watcher.target.bundleID))"
```

**Step 4: Update `TestSupport.swift` — remove `name` from `makeWatcher`**

```swift
func makeWatcher(sensitivity: Double) -> Watcher {
  Watcher(
    id: UUID(),
    target: WindowBinding(bundleID: "com.example.app", titleMatch: .exact("Window")),
    rect: CGRect(x: 0, y: 0, width: 10, height: 10),
    sensitivity: sensitivity,
    tickIntervalSeconds: 1,
    command: "true",
    armed: false
  )
}
```

**Step 5: Update `PersistenceTests.swift` — remove `name` from all `Watcher` constructors**

- Remove `name: "Main CI"` and `name: "Chat badge"` from the inline `Watcher(...)` calls.
- Simplify `makePersistedWatcher` — drop the `name` parameter entirely:

```swift
private func makePersistedWatcher(armed: Bool) -> Watcher {
  Watcher(
    id: UUID(),
    target: WindowBinding(bundleID: "com.example", titleMatch: .regex(".*")),
    rect: CGRect(x: 0, y: 0, width: 10, height: 10),
    sensitivity: 0.7,
    tickIntervalSeconds: 1,
    command: "true",
    armed: armed
  )
}
```

Update the two call sites from `makePersistedWatcher(name: "First", armed: true)` → `makePersistedWatcher(armed: true)`, etc.

**Step 6: Update `HookStageTests.swift`**

- Remove `name: "CI Badge"` from the `Watcher(...)` constructor.
- Remove `command: "notify \"$WATCH_NAME\""` — change to `command: "notify \"$WATCH_WINDOW_TITLE\""` (or any command; the test doesn't exercise shell execution).
- Replace the assertion:
  ```swift
  XCTAssertEqual(invocation?.env["WATCH_NAME"], "CI Badge")
  ```
  with a check that `WATCH_NAME` is absent and `WATCH_WINDOW_TITLE` is present:
  ```swift
  XCTAssertNil(invocation?.env["WATCH_NAME"])
  XCTAssertEqual(invocation?.env["WATCH_WINDOW_TITLE"], "Builds")
  XCTAssertEqual(invocation?.env["WATCH_WINDOW_APP"], "com.example.ci")
  ```

**Step 7: Add forward-compatibility decode test to `PersistenceTests.swift`**

Swift's `JSONDecoder` silently ignores unknown keys, so old `watchers.json` files with a `name` field should load cleanly. Prove it explicitly:

```swift
func testLoadLegacyJsonWithNameFieldSucceeds() throws {
  let directory = try makeTemporaryDirectory()
  let url = directory.appendingPathComponent("watchers.json")
  // Minimal JSON that includes a "name" key that no longer exists in Watcher.
  let json = """
  [{"id":"11111111-1111-1111-1111-111111111111","name":"Legacy Name",\
  "target":{"bundleID":"com.example","titleMatch":{"exact":"Window"},\
  "windowIDHint":null,"lastKnownBounds":null},\
  "rect":{"x":0,"y":0,"width":10,"height":10},\
  "sensitivity":0.5,"tickIntervalSeconds":1,"command":"true","armed":false}]
  """
  try json.write(to: url, atomically: true, encoding: .utf8)
  let loaded = try WatcherPersistence(url: url).load()
  XCTAssertEqual(loaded.count, 1)
  XCTAssertEqual(loaded[0].target.bundleID, "com.example")
}
```

**Step 8: Run all Core tests**

```
swift test --filter PixelWatchCoreTests
```
Expected: all pass.

**Step 9: Commit**

Write to `tmp/commit-msg.txt`:
```
refactor: remove name field from Watcher model and Core call sites

WATCH_NAME hook env var dropped — WATCH_WINDOW_APP and WATCH_WINDOW_TITLE
already carry the same information. Error messages now identify watchers
by titleMatch literal + bundleID.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
Claude-Session: f30bc643-dc00-4b1b-9ae6-49154b9a3d3b
```
Stage and commit:
```
git add Sources/PixelWatchCore/Models.swift Sources/PixelWatchCore/Stages.swift Sources/PixelWatchCore/WatcherArmService.swift Tests/PixelWatchCoreTests/TestSupport.swift Tests/PixelWatchCoreTests/PersistenceTests.swift Tests/PixelWatchCoreTests/HookStageTests.swift Tests/PixelWatchCoreTests/TitleMatchTests.swift
git commit -F tmp/commit-msg.txt
rm tmp/commit-msg.txt
```

---

### Task 3: Remove `name` from AppSupport types and UI

**Files:**
- Modify: `Sources/PixelWatchAppSupport/PopoverModel.swift`
- Modify: `Sources/PixelWatchAppSupport/NewWatcherCoordinator.swift`
- Modify: `Sources/PixelWatchAppSupport/ConfigureWatcherSheet.swift`
- Modify: `Sources/pixelwatch/PixelWatchMain.swift`
- Modify: `Tests/PixelWatchAppSupportTests/PopoverModelTests.swift`

**Step 1: Remove `name` from `WatcherThumbnailItem` in `PopoverModel.swift`**

`name` is never rendered in `PopoverGridView` (the cell shows state text), so this is pure removal:

```swift
public struct WatcherThumbnailItem: Identifiable, Sendable {
  public let id: WatcherID
  public let state: WatcherState
  public let latestFrame: PixelBuffer?

  public init(id: WatcherID, state: WatcherState, latestFrame: PixelBuffer?) {
    self.id = id
    self.state = state
    self.latestFrame = latestFrame
  }
}
```

**Step 2: Update `PopoverModelTests.swift`**

- Remove `name:` label from all `WatcherThumbnailItem(...)` calls.
- Remove `XCTAssertEqual(model.items[0].name, "Test")` — replace with a check on `state`:
  ```swift
  XCTAssertEqual(model.items[0].state, .idle)
  ```
- In `testWatcherThumbnailItemIsIdentifiableById`, remove `name:` labels.

**Step 3: Remove `name` from `WatcherDraft` in `NewWatcherCoordinator.swift`**

`WatcherDraft` struct: remove `public var name: String` and its `init` parameter.

Update the two construction sites in the same file and in `PixelWatchMain.swift`:
- `NewWatcherCoordinator.startNewWatcher` creates `WatcherDraft(window: snapshot, name: snapshot.title, ...)` → drop `name:`.
- `PixelWatchMain.swift` (the `dropAt` path, ~line 246) creates `WatcherDraft(window: windowSnapshot, name: ..., ...)` → drop `name:`.

**Step 4: Remove name from `ConfigureWatcherSheet.swift`**

The view and presenter are wired together via `onSave`. Remove `name` from both.

In `ConfigureWatcherSheetView`:
- Remove `@State private var name: String`
- Remove `_name = State(initialValue: draft.name)` from `init`
- Remove `TextField("Name", text: $name)` from the `Form`
- Change `let onSave: (String, Double, String, Bool) -> Void` → `let onSave: (Double, String, Bool) -> Void`
- Update button actions: `onSave(name, sensitivity, command, false)` → `onSave(sensitivity, command, false)`, etc.

In `AppKitConfigureWatcherSheetPresenter.present`:
- Update the `save` closure signature to `(Double, String, Bool) -> Void`
- Remove `name` from the `Watcher(...)` constructor call

The `ConfigureWatcherSheetPresenting` protocol's `present` method signature is unchanged (it takes a `WatcherDraft` and returns a `Watcher?`).

**Step 5: Update `refreshPopover` in `PixelWatchMain.swift`**

Change `WatcherThumbnailItem(id:name:state:latestFrame:)` → `WatcherThumbnailItem(id:state:latestFrame:)`:

```swift
items.append(WatcherThumbnailItem(
  id: watcher.id,
  state: snap?.state ?? .idle,
  latestFrame: snap?.latestFrame
))
```

**Step 6: Run all tests**

```
swift test
```
Expected: all pass.

**Step 7: Commit**

Write to `tmp/commit-msg.txt`:
```
refactor: remove name from AppSupport types, WatcherDraft, and configure sheet

WatcherThumbnailItem, WatcherDraft, and ConfigureWatcherSheetView no longer
carry a name field. The sheet now only configures sensitivity and command.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
Claude-Session: f30bc643-dc00-4b1b-9ae6-49154b9a3d3b
```
Stage and commit:
```
git add Sources/PixelWatchAppSupport/PopoverModel.swift Sources/PixelWatchAppSupport/NewWatcherCoordinator.swift Sources/PixelWatchAppSupport/ConfigureWatcherSheet.swift Sources/pixelwatch/PixelWatchMain.swift Tests/PixelWatchAppSupportTests/PopoverModelTests.swift
git commit -F tmp/commit-msg.txt
rm tmp/commit-msg.txt
```
