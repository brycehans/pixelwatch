# Notification Command Mode — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace `Watcher.command: String` with a `CommandMode` enum so the configure sheet can offer "Send a notification" (native `UNUserNotificationCenter`) vs "Run a command" (existing shell path).

**Architecture:** `CommandMode` lives in `PixelWatchCore/Models.swift`. `Watcher` gets a custom `Codable` impl that migrates legacy `command: String` JSON → `.shell(cmd)`. `HookStage` grows a `NotificationPosting` protocol seam (injected like `HookRunning`) and branches on `commandMode`. `ConfigureWatcherSheet` gets a segmented picker that drives two separate `@State` strings (body vs shell command), assembling a `CommandMode` on save. Launch-time notification auth is wired in `PixelWatchMain.applicationDidFinishLaunching`.

**Tech Stack:** Swift 6, SwiftPM, `UserNotifications` framework (system, no Package.swift change needed), `XCTest`.

---

### Task 1: Add `CommandMode` enum to Models.swift

**Files:**
- Modify: `Sources/PixelWatchCore/Models.swift`

**Step 1: Add the enum above `Watcher`**

In `Models.swift`, insert after the `import` block and before `public struct Watcher`:

```swift
public enum CommandMode: Codable, Equatable, Sendable {
  case shell(String)
  case notification(body: String)
}
```

**Step 2: Replace `command: String` with `commandMode: CommandMode` in `Watcher`**

Replace the stored property and memberwise init parameter:

```swift
// Before:
public var command: String
// …
public init(
  id: WatcherID,
  target: WindowBinding,
  rect: CGRect,
  sensitivity: Double,
  tickIntervalSeconds: Double,
  command: String,
  armed: Bool
) {
  // …
  self.command = command
}

// After:
public var commandMode: CommandMode
// …
public init(
  id: WatcherID,
  target: WindowBinding,
  rect: CGRect,
  sensitivity: Double,
  tickIntervalSeconds: Double,
  commandMode: CommandMode,
  armed: Bool
) {
  // …
  self.commandMode = commandMode
}
```

**Step 3: Add custom Codable to `Watcher` for migration**

`Watcher` currently uses synthesized Codable. Because we're adding a custom `init(from:)`, we must also implement `encode(to:)`. Add a `CodingKeys` enum and both methods inside `Watcher`. The decoder reads `commandMode` first; if absent (legacy JSON), reads `command: String` and wraps it as `.shell`.

```swift
// Inside `public struct Watcher`:

private enum CodingKeys: String, CodingKey {
  case id, target, rect, sensitivity, tickIntervalSeconds, armed
  case commandMode
  case command // legacy key — decode only
}

public init(from decoder: Decoder) throws {
  let c = try decoder.container(keyedBy: CodingKeys.self)
  id = try c.decode(WatcherID.self, forKey: .id)
  target = try c.decode(WindowBinding.self, forKey: .target)
  rect = try c.decode(CGRect.self, forKey: .rect)
  sensitivity = try c.decode(Double.self, forKey: .sensitivity)
  tickIntervalSeconds = try c.decode(Double.self, forKey: .tickIntervalSeconds)
  armed = try c.decode(Bool.self, forKey: .armed)
  if let mode = try c.decodeIfPresent(CommandMode.self, forKey: .commandMode) {
    commandMode = mode
  } else {
    let cmd = (try? c.decode(String.self, forKey: .command)) ?? ""
    commandMode = .shell(cmd)
  }
}

public func encode(to encoder: Encoder) throws {
  var c = encoder.container(keyedBy: CodingKeys.self)
  try c.encode(id, forKey: .id)
  try c.encode(target, forKey: .target)
  try c.encode(rect, forKey: .rect)
  try c.encode(sensitivity, forKey: .sensitivity)
  try c.encode(tickIntervalSeconds, forKey: .tickIntervalSeconds)
  try c.encode(armed, forKey: .armed)
  try c.encode(commandMode, forKey: .commandMode)
}
```

**Step 4: Verify the package still compiles (it won't — there are callers to fix, but errors should be only `command:` label mismatches)**

Run: `swift build 2>&1 | head -40`

Expected: compile errors mentioning `command` on `Watcher` init call-sites. That's correct — proceed to Task 2.

---

### Task 2: Fix `PixelWatchCore` callers of `Watcher.command`

**Files:**
- Modify: `Sources/PixelWatchCore/Stages.swift`
- Modify: `Tests/PixelWatchCoreTests/TestSupport.swift`
- Modify: `Tests/PixelWatchCoreTests/PersistenceTests.swift`
- Modify: `Tests/PixelWatchCoreTests/HookStageTests.swift`

**Step 1: Fix `Stages.swift`**

`HookStage` reads `fire.watcher.command` in two places. Replace both with a computed display string:

```swift
// In FireContext (around line 141 and 145):
// Before:
command: fire.watcher.command,
// …
command: fire.watcher.command,

// After — derive a display string for the event:
command: fire.watcher.commandMode.displayString,
// …
command: fire.watcher.commandMode.displayString,
```

Add a computed property to `CommandMode` in `Models.swift`:

```swift
// Inside CommandMode:
public var displayString: String {
  switch self {
  case .shell(let cmd): return cmd
  case .notification(let body): return "[notification] \(body)"
  }
}
```

Also fix the runner call — it still passes a shell command string. The runner should only be called for `.shell`. We'll fix the dispatch in Task 5; for now just make it compile by calling `runner.run(command: fire.watcher.commandMode.displayString, ...)` (wrong semantics, but compiles — Task 5 adds the real branch).

**Step 2: Fix `TestSupport.makeWatcher`**

```swift
// Before:
func makeWatcher(sensitivity: Double) -> Watcher {
  Watcher(
    …
    command: "true",
    …
  )
}

// After:
func makeWatcher(sensitivity: Double) -> Watcher {
  Watcher(
    …
    commandMode: .shell("true"),
    …
  )
}
```

**Step 3: Fix `PersistenceTests`**

Update all `Watcher(…, command:…)` call-sites:

```swift
// makePersistedWatcher:
Watcher(…, commandMode: .shell("true"), …)

// testSaveAndLoadRoundTripsWatchers — two watchers:
Watcher(…, commandMode: .shell("notify"), …)
Watcher(…, commandMode: .shell("echo changed"), …)
```

**Step 4: Fix `HookStageTests`**

Update the watcher fixture:

```swift
// Before:
command: "notify \"$WATCH_WINDOW_TITLE\"",

// After:
commandMode: .shell("notify \"$WATCH_WINDOW_TITLE\""),
```

Fix the assertion that used `watcher.command`:

```swift
// Before:
XCTAssertEqual(command, watcher.command)
// …
XCTAssertEqual(invocation?.command, watcher.command)

// After:
XCTAssertEqual(command, "notify \"$WATCH_WINDOW_TITLE\"")
// …
XCTAssertEqual(invocation?.command, "notify \"$WATCH_WINDOW_TITLE\"")
```

**Step 5: Build Core only to verify**

Run: `swift build --target PixelWatchCore 2>&1 | head -20`

Expected: 0 errors in Core. AppSupport/executable will still fail — that's fine.

---

### Task 3: Fix `PixelWatchAppSupport` callers

**Files:**
- Modify: `Sources/PixelWatchAppSupport/NewWatcherCoordinator.swift`
- Modify: `Sources/PixelWatchAppSupport/ConfigureWatcherSheet.swift`

**Step 1: Update `WatcherDraft` in `NewWatcherCoordinator.swift`**

```swift
// Before:
public var command: String
public init(window: WindowSnapshot, sensitivity: Double, command: String, armed: Bool) {
  …
  self.command = command
}

// After:
public var commandMode: CommandMode
public init(window: WindowSnapshot, sensitivity: Double, commandMode: CommandMode, armed: Bool) {
  …
  self.commandMode = commandMode
}
```

Update the `WatcherDraft` construction in `startNewWatcher()`:

```swift
// Before:
let draft = WatcherDraft(window: snapshot, sensitivity: 0.5, command: "", armed: false)

// After:
let draft = WatcherDraft(
  window: snapshot,
  sensitivity: 0.5,
  commandMode: .notification(body: "Change found on \(snapshot.title)"),
  armed: false
)
```

**Step 2: Rewrite `ConfigureWatcherSheetView` in `ConfigureWatcherSheet.swift`**

Replace the entire `ConfigureWatcherSheetView` struct:

```swift
struct ConfigureWatcherSheetView: View {
  private enum UIMode { case notification, shell }

  @State private var sensitivity: Double
  @State private var mode: UIMode
  @State private var notificationBody: String
  @State private var shellCommand: String

  let onSave: (Double, CommandMode, Bool) -> Void
  let onCancel: () -> Void

  init(
    draft: WatcherDraft,
    onSave: @escaping (Double, CommandMode, Bool) -> Void,
    onCancel: @escaping () -> Void
  ) {
    _sensitivity = State(initialValue: draft.sensitivity)
    switch draft.commandMode {
    case .notification(let body):
      _mode = State(initialValue: .notification)
      _notificationBody = State(initialValue: body)
      _shellCommand = State(initialValue: "")
    case .shell(let cmd):
      _mode = State(initialValue: .shell)
      _notificationBody = State(initialValue: "")
      _shellCommand = State(initialValue: cmd)
    }
    self.onSave = onSave
    self.onCancel = onCancel
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("New Watcher")
        .font(.headline)

      Form {
        VStack(alignment: .leading, spacing: 4) {
          Text("Sensitivity: \(String(format: "%.2f", sensitivity))")
          Slider(value: $sensitivity, in: 0...1)
        }
        Picker("When it fires", selection: $mode) {
          Text("Notification").tag(UIMode.notification)
          Text("Run a command").tag(UIMode.shell)
        }
        .pickerStyle(.segmented)
        switch mode {
        case .notification:
          TextField("Message", text: $notificationBody)
        case .shell:
          TextField("Command", text: $shellCommand)
        }
      }

      HStack {
        Button("Cancel") { onCancel() }
          .keyboardShortcut(.escape, modifiers: [])
        Spacer()
        Button("Save") { onSave(sensitivity, assembledMode, false) }
          .keyboardShortcut(.return, modifiers: [])
        Button("Save & Arm") { onSave(sensitivity, assembledMode, true) }
          .keyboardShortcut(.return, modifiers: [.command])
      }
    }
    .padding(20)
    .frame(width: 400)
  }

  private var assembledMode: CommandMode {
    switch mode {
    case .notification: .notification(body: notificationBody)
    case .shell: .shell(shellCommand)
    }
  }
}
```

**Step 3: Update `AppKitConfigureWatcherSheetPresenter` save closure**

In the `save` closure (around line 91), the `command` local is now `commandMode: CommandMode`:

```swift
let save: (Double, CommandMode, Bool) -> Void = { [weak panel] sensitivity, commandMode, armed in
  guard !resumed else { return }
  resumed = true
  panel?.close()
  let screenRect = overlay.frozenRect ?? CGRect(x: 0, y: 0, width: 100, height: 100)
  let rect = windowRelativeRect(fromScreen: screenRect, windowBounds: draft.window.bounds)
  let target = WindowBinding(
    bundleID: draft.window.bundleID,
    titleMatch: .exact(draft.window.title),
    windowIDHint: draft.window.windowID,
    lastKnownBounds: draft.window.bounds
  )
  let watcher = Watcher(
    id: UUID(),
    target: target,
    rect: rect,
    sensitivity: sensitivity,
    tickIntervalSeconds: 1.0,
    commandMode: commandMode,
    armed: armed
  )
  continuation.resume(returning: watcher)
}
```

**Step 4: Build AppSupport to verify**

Run: `swift build --target PixelWatchAppSupport 2>&1 | head -20`

Expected: 0 errors.

---

### Task 4: Fix `PixelWatchMain.swift` `WatcherDraft` call-site

**Files:**
- Modify: `Sources/pixelwatch/PixelWatchMain.swift`

**Step 1: Fix the `handleDrop` WatcherDraft (around line 296–301)**

```swift
// Before:
let draft = WatcherDraft(
  window: windowSnapshot,
  sensitivity: 0.5,
  command: "",
  armed: false
)

// After:
let draft = WatcherDraft(
  window: windowSnapshot,
  sensitivity: 0.5,
  commandMode: .notification(body: "Change found on \(windowSnapshot.title)"),
  armed: false
)
```

**Step 2: Build the full package**

Run: `swift build 2>&1 | head -30`

Expected: 0 errors. (The notification path still just calls `runner.run` with the display string — functionally wrong but compiles. Fixed in Task 5.)

---

### Task 5: Add `NotificationPosting` protocol and update `HookStage` dispatch

**Files:**
- Modify: `Sources/PixelWatchCore/HookRunner.swift`
- Modify: `Sources/PixelWatchCore/Stages.swift`

**Step 1: Add `NotificationPosting` protocol + live impl to `HookRunner.swift`**

Append to the end of `HookRunner.swift`:

```swift
// MARK: - NotificationPosting

import UserNotifications

public protocol NotificationPosting: Sendable {
  func post(body: String, identifier: String) async
}

public final class UNNotificationPoster: NotificationPosting, @unchecked Sendable {
  public init() {}

  public func post(body: String, identifier: String) async {
    let content = UNMutableNotificationContent()
    content.title = "PixelWatch"
    content.body = body
    let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
    try? await UNUserNotificationCenter.current().add(request)
  }
}

public struct StubNotificationPoster: NotificationPosting {
  public private(set) var postedBodies: [String] = []

  public init() {}

  public mutating func post(body: String, identifier: String) async {
    postedBodies.append(body)
  }
}
```

> **Swift 6 note:** If the compiler flags `UNUserNotificationCenter.current()` as `@MainActor`-only, replace the `post` body with:
> ```swift
> let center = await MainActor.run { UNUserNotificationCenter.current() }
> try? await center.add(request)
> ```

**Step 2: Update `HookStage.start` in `Stages.swift`**

Add `poster` parameter and replace the single runner call with a branch:

```swift
public static func start(
  bus: EventBus,
  store: WatcherStore,
  runner: some HookRunning = LiveHookRunner(),
  poster: some NotificationPosting = UNNotificationPoster(),
  timeout: TimeInterval = 30
) -> Task<Void, Never> {
  Task {
    var events = await bus.subscribe().makeAsyncIterator()
    while !Task.isCancelled, let event = await events.next() {
      guard let fire = await FireContext(event: event, store: store) else {
        continue
      }
      switch fire.watcher.commandMode {
      case .shell(let cmd):
        await bus.publish(.hookStarted(
          watcherID: fire.watcher.id,
          command: cmd,
          reason: fire.reason
        ))
        let result = await runner.run(command: cmd, env: fire.env, timeout: timeout)
        await bus.publish(.hookFinished(
          watcherID: fire.watcher.id,
          exit: result.exit,
          stdout: result.stdout,
          stderr: result.stderr
        ))
      case .notification(let body):
        await bus.publish(.hookStarted(
          watcherID: fire.watcher.id,
          command: "[notification] \(body)",
          reason: fire.reason
        ))
        let id = "\(fire.watcher.id.uuidString)-\(fire.reason.environmentValue)"
        await poster.post(body: body, identifier: id)
        await bus.publish(.hookFinished(
          watcherID: fire.watcher.id,
          exit: 0,
          stdout: "",
          stderr: ""
        ))
      }
    }
  }
}
```

**Step 3: Build**

Run: `swift build 2>&1 | head -20`

Expected: 0 errors.

---

### Task 6: Add `HookStage` notification-path test

**Files:**
- Modify: `Tests/PixelWatchCoreTests/HookStageTests.swift`

**Step 1: Write the failing test**

`StubNotificationPoster` is a struct (value type) — we can't use it as a protocol existential across actor boundaries cleanly. For the test, define a simple `RecordingNotificationPoster` actor inside the test file:

```swift
private actor RecordingNotificationPoster: NotificationPosting {
  private(set) var posted: [(body: String, identifier: String)] = []

  func post(body: String, identifier: String) async {
    posted.append((body: body, identifier: identifier))
  }
}
```

Add this test method to `HookStageTests`:

```swift
func testNotificationModePostsAndPublishesLifecycleEvents() async {
  let bus = EventBus()
  let store = WatcherStore(bus: bus)
  let runner = RecordingHookRunner(result: HookResult(exit: 0, stdout: "", stderr: "", timedOut: false))
  let poster = RecordingNotificationPoster()
  let watcher = Watcher(
    id: UUID(),
    target: WindowBinding(bundleID: "com.example.ci", titleMatch: .exact("Builds")),
    rect: CGRect(x: 0, y: 0, width: 10, height: 10),
    sensitivity: 0.5,
    tickIntervalSeconds: 1,
    commandMode: .notification(body: "Build done"),
    armed: false
  )
  let frame = PixelBuffer(width: 1, height: 1, linearRGB: [1, 1, 1])

  await store.add(watcher)
  await store.start()
  let hookTask = HookStage.start(bus: bus, store: store, runner: runner, poster: poster)
  let events = await EventReader(stream: bus.subscribe())
  await events.start()
  await waitUntil { await bus.subscriberCount == 3 }
  defer { hookTask.cancel() }

  await bus.publish(.thresholdExceeded(watcherID: watcher.id, score: 0.9, frame: frame))

  let started = await events.next { if case .hookStarted = $0 { return true }; return false }
  let finished = await events.next { if case .hookFinished = $0 { return true }; return false }

  guard case let .hookStarted(_, command, reason) = started else {
    return XCTFail("expected hookStarted")
  }
  XCTAssertEqual(command, "[notification] Build done")
  XCTAssertEqual(reason, .pixelChange)

  guard case let .hookFinished(_, exit, stdout, stderr) = finished else {
    return XCTFail("expected hookFinished")
  }
  XCTAssertEqual(exit, 0)
  XCTAssertEqual(stdout, "")
  XCTAssertEqual(stderr, "")

  // Shell runner must NOT have been called.
  let invocations = await runner.invocations
  XCTAssertTrue(invocations.isEmpty, "shell runner should not be called for notification mode")

  let posts = await poster.posted
  XCTAssertEqual(posts.count, 1)
  XCTAssertEqual(posts[0].body, "Build done")
}
```

**Step 2: Run the test**

Run: `swift test --filter PixelWatchCoreTests.HookStageTests/testNotificationModePostsAndPublishesLifecycleEvents 2>&1 | tail -10`

Expected: PASS.

**Step 3: Run all HookStage tests**

Run: `swift test --filter PixelWatchCoreTests.HookStageTests 2>&1 | tail -10`

Expected: all pass.

---

### Task 7: Add persistence migration and round-trip tests

**Files:**
- Modify: `Tests/PixelWatchCoreTests/PersistenceTests.swift`

**Step 1: Add `.notification` round-trip test**

```swift
func testSaveAndLoadNotificationModeRoundTrips() throws {
  let directory = try makeTemporaryDirectory()
  let persistence = WatcherPersistence(url: directory.appendingPathComponent("watchers.json"))
  let watcher = Watcher(
    id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
    target: WindowBinding(bundleID: "com.example", titleMatch: .exact("Window")),
    rect: CGRect(x: 0, y: 0, width: 10, height: 10),
    sensitivity: 0.5,
    tickIntervalSeconds: 1,
    commandMode: .notification(body: "Change found on Window"),
    armed: false
  )
  try persistence.save([watcher])
  XCTAssertEqual(try persistence.load(), [watcher])
}
```

**Step 2: Add legacy `command` string migration test**

```swift
func testLoadLegacyCommandStringMigratestoShellMode() throws {
  let directory = try makeTemporaryDirectory()
  let url = directory.appendingPathComponent("watchers.json")
  // Legacy JSON with `command` key, no `commandMode`.
  let json = """
  [{"id":"11111111-1111-1111-1111-111111111111",\
  "target":{"bundleID":"com.example","titleMatch":{"exact":{"_0":"Window"}},\
  "windowIDHint":null,"lastKnownBounds":null},\
  "rect":[[0,0],[10,10]],\
  "sensitivity":0.5,"tickIntervalSeconds":1,"command":"true","armed":false}]
  """
  try json.write(to: url, atomically: true, encoding: .utf8)
  let loaded = try WatcherPersistence(url: url).load()
  XCTAssertEqual(loaded.count, 1)
  XCTAssertEqual(loaded[0].commandMode, .shell("true"))
}
```

**Step 3: Run persistence tests**

Run: `swift test --filter PixelWatchCoreTests.PersistenceTests 2>&1 | tail -10`

Expected: all pass.

---

### Task 8: Wire launch-time notification permission in `PixelWatchMain.swift`

**Files:**
- Modify: `Sources/pixelwatch/PixelWatchMain.swift`

**Step 1: Add `import UserNotifications` at the top of `PixelWatchMain.swift`**

**Step 2: Request authorization in `applicationDidFinishLaunching`**

After the existing `startRuntime()` / `startSyncTimer()` calls, add:

```swift
Task {
  try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])
}
```

**Step 3: Build the full package**

Run: `swift build 2>&1 | head -20`

Expected: 0 errors.

---

### Task 9: Run all tests

Run: `swift test 2>&1 | tail -20`

Expected: all tests pass.

---

### Task 10: Commit

Stage:
```
Sources/PixelWatchCore/Models.swift
Sources/PixelWatchCore/Stages.swift
Sources/PixelWatchCore/HookRunner.swift
Sources/PixelWatchAppSupport/NewWatcherCoordinator.swift
Sources/PixelWatchAppSupport/ConfigureWatcherSheet.swift
Sources/pixelwatch/PixelWatchMain.swift
Tests/PixelWatchCoreTests/TestSupport.swift
Tests/PixelWatchCoreTests/PersistenceTests.swift
Tests/PixelWatchCoreTests/HookStageTests.swift
```

Commit message (`tmp/commit-msg.txt`):
```
feat: add notification command mode to configure-watcher sheet

Replace Watcher.command: String with CommandMode enum (.shell / .notification).
HookStage dispatches natively via UNUserNotificationCenter for notification
watchers. Configure sheet shows a segmented picker; legacy watchers.json files
migrate transparently via custom Codable init.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
Claude-Session: 029ff26b-cda8-4d1c-93dd-74439134999a
```
