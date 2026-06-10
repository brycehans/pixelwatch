# New Watcher Overlay Flow Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the focused-window new-watcher flow with a 100x100 cursor-following overlay, no-window alerting, persistent window-attached overlays, and state-driven border colors.

**Architecture:** Add a small `PixelWatchAppSupport` library to hold the testable UI-coordinator and overlay logic, leaving `pixelwatch` as a thin AppKit shell. The coordinator asks for the current focused window, starts an overlay session anchored to that window, and hands the frozen rect into the existing watcher creation and arm services. A separate overlay manager keeps every watcher square visible across all states and updates position/visibility by polling the target window, while border color reflects runtime state.

**Tech Stack:** Swift 6, AppKit, SwiftUI, CoreGraphics, existing `PixelWatchCore`, XCTest.

---

### Task 1: Package And Test Harness

**Files:**
- Modify: `Package.swift`
- Create: `Tests/PixelWatchAppSupportTests/OverlayAppearanceTests.swift`
- Create: `Tests/PixelWatchAppSupportTests/NewWatcherCoordinatorTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import CoreGraphics
import XCTest
@testable import PixelWatchAppSupport

final class OverlayAppearanceTests: XCTestCase {
  func testBorderColorMatchesWatcherState() {
    XCTAssertEqual(OverlayAppearance.borderColor(for: .idle), .gray)
    XCTAssertEqual(OverlayAppearance.borderColor(for: .armed), .systemGreen)
    XCTAssertEqual(OverlayAppearance.borderColor(for: .triggered), .systemRed)
    XCTAssertEqual(OverlayAppearance.borderColor(for: .errored("bad")), .systemOrange)
  }
}
```

```swift
import CoreGraphics
import XCTest
@testable import PixelWatchAppSupport

final class NewWatcherCoordinatorTests: XCTestCase {
  func testNoFocusedWindowShowsAlertAndStops() async {
    let alert = RecordingAlertPresenter()
    let overlay = RecordingOverlaySessionFactory()
    let coordinator = NewWatcherCoordinator(
      focusedWindowProvider: StubFocusedWindowProvider(window: nil),
      alertPresenter: alert,
      overlaySessionFactory: overlay
    )

    await coordinator.startNewWatcher()

    XCTAssertEqual(alert.messages, ["PixelWatch could not find a usable focused window."])
    XCTAssertEqual(overlay.startedCount, 0)
  }
}
```

```swift
import CoreGraphics

private struct StubFocusedWindowProvider: FocusedWindowProviding {
  let window: WindowSnapshot?

  func focusedWindow() -> WindowSnapshot? {
    window
  }
}

private final class RecordingAlertPresenter: AlertPresenting {
  private(set) var messages: [String] = []

  func show(message: String) {
    messages.append(message)
  }
}

private final class RecordingOverlaySessionFactory: OverlaySessionFactory {
  private(set) var startedCount = 0

  func makeSession(window: WindowSnapshot) -> WatcherOverlaySession {
    startedCount += 1
    return RecordingOverlaySession(window: window)
  }
}

private final class RecordingOverlaySession: WatcherOverlaySession {
  let window: WindowSnapshot
  private(set) var frozenRect: CGRect?

  init(window: WindowSnapshot) {
    self.window = window
  }

  func freeze() {
    frozenRect = CGRect(x: 0, y: 0, width: 100, height: 100)
  }
}
```

- [ ] **Step 2: Run the tests and verify they fail**

Run: `swift test --filter PixelWatchAppSupportTests`

Expected: build/test failure with missing `PixelWatchAppSupport`, `OverlayAppearance`, and `NewWatcherCoordinator` symbols.

- [ ] **Step 3: Add the library and test target**

```swift
// Package.swift
products: [
  .library(name: "PixelWatchCore", targets: ["PixelWatchCore"]),
  .library(name: "PixelWatchAppSupport", targets: ["PixelWatchAppSupport"]),
  .executable(name: "pixelwatch", targets: ["pixelwatch"]),
  .executable(name: "pixelwatch-bench", targets: ["pixelwatch-bench"]),
],
targets: [
  .target(name: "PixelWatchCore", path: "Sources/PixelWatchCore"),
  .target(
    name: "PixelWatchAppSupport",
    dependencies: ["PixelWatchCore"],
    path: "Sources/PixelWatchAppSupport"
  ),
  .executableTarget(
    name: "pixelwatch",
    dependencies: ["PixelWatchCore", "PixelWatchAppSupport"],
    path: "Sources/pixelwatch"
  ),
  .testTarget(
    name: "PixelWatchAppSupportTests",
    dependencies: ["PixelWatchAppSupport"],
    path: "Tests/PixelWatchAppSupportTests"
  ),
]
```

- [ ] **Step 4: Run the tests again and verify they still fail on missing implementation symbols**

Run: `swift test --filter PixelWatchAppSupportTests`

Expected: compile now reaches the new target, then fails on missing `OverlayAppearance` and `NewWatcherCoordinator`.

- [ ] **Step 5: Commit the scaffolding**

```bash
git add Package.swift Tests/PixelWatchAppSupportTests/OverlayAppearanceTests.swift Tests/PixelWatchAppSupportTests/NewWatcherCoordinatorTests.swift
git commit -m "test: scaffold new watcher overlay flow"
```

### Task 2: Focused Window Provider

**Files:**
- Create: `Sources/PixelWatchAppSupport/WindowSnapshot.swift`
- Create: `Sources/PixelWatchAppSupport/FocusedWindowProvider.swift`
- Create: `Tests/PixelWatchAppSupportTests/FocusedWindowProviderTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import CoreGraphics
import XCTest
@testable import PixelWatchAppSupport

final class FocusedWindowProviderTests: XCTestCase {
  func testProviderReturnsFrontmostOnscreenWindow() {
    let provider = CGFocusedWindowProvider(
      frontmostApplication: { FrontmostApp(pid: 99) },
      windowInfoProvider: {
        [
          [
            "kCGWindowOwnerPID": 99,
            "kCGWindowNumber": 42,
            "kCGWindowName": "Editor",
            "kCGWindowBounds": ["X": 10, "Y": 20, "Width": 300, "Height": 200],
            "kCGWindowIsOnscreen": true,
          ],
        ]
      }
    )

    XCTAssertEqual(provider.focusedWindow()?.windowID, 42)
  }
}
```

- [ ] **Step 2: Run the tests and verify they fail**

Run: `swift test --filter FocusedWindowProviderTests`

Expected: missing `CGFocusedWindowProvider` and `WindowSnapshot` symbols.

- [ ] **Step 3: Implement the provider and snapshot model**

```swift
public struct WindowSnapshot: Equatable, Sendable {
  public let windowID: UInt32
  public let processID: pid_t
  public let bundleID: String
  public let title: String
  public let bounds: CGRect
  public let isVisible: Bool
}

public protocol FocusedWindowProviding: Sendable {
  func focusedWindow() -> WindowSnapshot?
}
```

Use `NSWorkspace.shared.frontmostApplication` by default, then scan `CGWindowListCopyWindowInfo` for the frontmost PID, layer 0, on-screen window. Keep the default initializer live and the data-source closures injectable for tests.

- [ ] **Step 4: Run the focused-window tests and verify they pass**

Run: `swift test --filter FocusedWindowProviderTests`

Expected: pass with the injected fake frontmost app and window list.

- [ ] **Step 5: Commit the provider**

```bash
git add Sources/PixelWatchAppSupport/WindowSnapshot.swift Sources/PixelWatchAppSupport/FocusedWindowProvider.swift Tests/PixelWatchAppSupportTests/FocusedWindowProviderTests.swift
git commit -m "feat: add focused window provider"
```

### Task 3: Overlay Session And State Mapping

**Files:**
- Create: `Sources/PixelWatchAppSupport/OverlayAppearance.swift`
- Create: `Sources/PixelWatchAppSupport/WatcherOverlayController.swift`
- Create: `Tests/PixelWatchAppSupportTests/WatcherOverlayControllerTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import CoreGraphics
import XCTest
@testable import PixelWatchAppSupport

final class WatcherOverlayControllerTests: XCTestCase {
  func testOverlayFollowsWindowAndFreezesOnClick() async {
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
    XCTAssertEqual(overlay.frames.first, CGRect(x: 120, y: 80, width: 100, height: 100))
    session.freeze()
    XCTAssertEqual(session.frozenRect, CGRect(x: 120, y: 80, width: 100, height: 100))
  }
}
```

```swift
import AppKit
import CoreGraphics

private struct StubWindowSnapshotProvider: WindowSnapshotProviding {
  let snapshots: [WindowSnapshot]

  func windowSnapshot(windowID: UInt32) -> WindowSnapshot? {
    snapshots.first { $0.windowID == windowID }
  }
}

private final class RecordingOverlayWindow: WatcherOverlayWindow {
  private(set) var frames: [CGRect] = []
  private(set) var borderColors: [NSColor] = []
  private(set) var visibleValues: [Bool] = []

  func setFrame(_ frame: CGRect) {
    frames.append(frame)
  }

  func setBorderColor(_ color: NSColor) {
    borderColors.append(color)
  }

  func setVisible(_ visible: Bool) {
    visibleValues.append(visible)
  }
}
```

- [ ] **Step 2: Run the tests and verify they fail**

Run: `swift test --filter WatcherOverlayControllerTests`

Expected: missing `WatcherOverlayController`, `OverlayAppearance`, and helper types.

- [ ] **Step 3: Implement the overlay controller**

```swift
import AppKit
import CoreGraphics

public enum OverlayAppearance {
  public static func borderColor(for state: WatcherState) -> NSColor {
    switch state {
    case .idle:
      .gray
    case .armed:
      .systemGreen
    case .triggered:
      .systemRed
    case .errored:
      .systemOrange
    }
  }
}

public protocol WatcherOverlayWindow: AnyObject {
  func setFrame(_ frame: CGRect)
  func setBorderColor(_ color: NSColor)
  func setVisible(_ visible: Bool)
}

public protocol WindowSnapshotProviding: Sendable {
  func windowSnapshot(windowID: UInt32) -> WindowSnapshot?
}

public protocol WatcherOverlaySession: Sendable {
  var frozenRect: CGRect? { get }
  func freeze()
}

public final class WatcherOverlayController {
  public func begin(windowID: UInt32) -> WatcherOverlaySession
  public func update(watcherID: WatcherID, state: WatcherState)
  public func sync()
}
```

The overlay window should be borderless, transparent, click-through except for the initial freeze click, and always visible in the same stacking/visibility state as the target window. It must remain visible after arm and after fire, with only the border color changing by state.

- [ ] **Step 4: Run the overlay tests and verify they pass**

Run: `swift test --filter WatcherOverlayControllerTests`

Expected: pass with the 100x100 cursor-following rect and frozen geometry.

- [ ] **Step 5: Commit the overlay session**

```bash
git add Sources/PixelWatchAppSupport/OverlayAppearance.swift Sources/PixelWatchAppSupport/WatcherOverlayController.swift Tests/PixelWatchAppSupportTests/WatcherOverlayControllerTests.swift
git commit -m "feat: add watcher overlay controller"
```

### Task 4: New Watcher Coordinator And Sheet

**Files:**
- Create: `Sources/PixelWatchAppSupport/NewWatcherCoordinator.swift`
- Create: `Sources/PixelWatchAppSupport/ConfigureWatcherSheet.swift`
- Modify: `Sources/pixelwatch/PixelWatchMain.swift`
- Modify: `Sources/pixelwatch/PixelWatchMain.swift` and/or add `Sources/pixelwatch/MenuBarController.swift` if splitting the delegate improves readability

- [ ] **Step 1: Write the failing tests**

```swift
import CoreGraphics
import XCTest
@testable import PixelWatchAppSupport

final class NewWatcherCoordinatorTests: XCTestCase {
  func testFocusedWindowStartsOverlayAndConfiguration() async {
    let alert = RecordingAlertPresenter()
    let overlay = RecordingOverlaySessionFactory()
    let sheet = RecordingConfigureWatcherSheetPresenter()
    let coordinator = NewWatcherCoordinator(
      focusedWindowProvider: StubFocusedWindowProvider(
        window: WindowSnapshot(
          windowID: 42,
          processID: 99,
          bundleID: "com.example",
          title: "Editor",
          bounds: CGRect(x: 100, y: 100, width: 500, height: 400),
          isVisible: true
        )
      ),
      alertPresenter: alert,
      overlaySessionFactory: overlay,
      configureSheetPresenter: sheet
    )

    await coordinator.startNewWatcher()

    XCTAssertEqual(alert.messages, [])
    XCTAssertEqual(overlay.startedCount, 1)
    XCTAssertEqual(sheet.presentedCount, 1)
  }
}
```

```swift
private final class RecordingConfigureWatcherSheetPresenter: ConfigureWatcherSheetPresenting {
  private(set) var presentedCount = 0

  func present(draft: WatcherDraft, overlay: WatcherOverlaySession) async -> Watcher? {
    presentedCount += 1
    _ = draft
    _ = overlay
    return nil
  }
}
```

- [ ] **Step 2: Run the tests and verify they fail**

Run: `swift test --filter NewWatcherCoordinatorTests`

Expected: missing `NewWatcherCoordinator`, `ConfigureWatcherSheet`, and supporting protocols.

- [ ] **Step 3: Implement the coordinator and sheet**

```swift
import AppKit
import CoreGraphics

public protocol AlertPresenting: Sendable {
  func show(message: String)
}

public protocol OverlaySessionFactory: Sendable {
  func makeSession(window: WindowSnapshot) -> WatcherOverlaySession
}

public protocol ConfigureWatcherSheetPresenting: Sendable {
  func present(draft: WatcherDraft, overlay: WatcherOverlaySession) async -> Watcher?
}

public struct WatcherDraft: Sendable {
  public var window: WindowSnapshot
  public var name: String
  public var sensitivity: Double
  public var command: String
  public var armed: Bool
}
```

The coordinator should:

1. Ask the focused-window provider for a target.
2. Show the alert and return early if there is no usable window.
3. Start the overlay at a default 100x100 square on the focused window.
4. Freeze on first click and hand the chosen rect into the existing watcher draft/configure path.
5. On save, persist the watcher and keep its overlay registered so the square remains visible in all states.

The sheet should expose the existing watcher fields needed for v1: name, sensitivity, command, and Save / Save & Arm actions. The app should keep the overlay attached and colorized after arm, not hide it when the watcher fires.

- [ ] **Step 4: Wire the menu item into the app**

Update `Sources/pixelwatch/PixelWatchMain.swift` so the status menu exposes `+ New watcher` and calls the coordinator from the app delegate. Keep the app target thin: the delegate owns the `EventBus`, `WatcherStore`, persistence, and the new watcher coordinator, but the logic lives in `PixelWatchAppSupport`.

- [ ] **Step 5: Run the sheet and app-target tests/build**

Run:

```bash
swift test
swift build --product pixelwatch
```

Expected: all tests pass and the `pixelwatch` product builds successfully.

- [ ] **Step 6: Commit the flow wiring**

```bash
git add Sources/PixelWatchAppSupport/NewWatcherCoordinator.swift Sources/PixelWatchAppSupport/ConfigureWatcherSheet.swift Sources/pixelwatch/PixelWatchMain.swift
git commit -m "feat: wire new watcher overlay flow"
```

### Task 5: Final Verification

**Files:**
- Review: `Package.swift`
- Review: `Sources/PixelWatchAppSupport/*`
- Review: `Sources/pixelwatch/*`
- Review: `Tests/PixelWatchAppSupportTests/*`

- [ ] **Step 1: Run the full test suite**

Run: `swift test`

Expected: all tests pass with 0 failures.

- [ ] **Step 2: Build the app product**

Run: `swift build --product pixelwatch`

Expected: build completes successfully.

- [ ] **Step 3: Report any remaining gaps**

If the flow still lacks a visible overlay, no-window alert, or state-colored border, keep those as explicit follow-up gaps rather than treating the slice as done.

## Self-Review

- Spec coverage: this plan covers the key-window fast path, the no-window alert, the 100x100 cursor-following square, overlay persistence across all states, state-colored borders, and the `pixelwatch` menu wiring.
- Placeholder scan: no TBD/TODO placeholders remain.
- Type consistency: `WindowSnapshot`, `FocusedWindowProviding`, `OverlayAppearance`, `WatcherOverlayController`, and `NewWatcherCoordinator` are named consistently across tasks.
- Scope check: the plan is focused on one feature slice and leaves settings/debug-socket work for later.
