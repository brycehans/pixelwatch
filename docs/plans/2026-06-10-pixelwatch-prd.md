# PixelWatch — Production App PRD

**Date:** 2026-06-10
**Status:** Ready for implementation
**Companion design doc:** `2026-06-10-pixelwatch-design.md` (architecture + UI flows)
**Companion bench:** complete (`2026-06-10-pixelwatch-bench-design.md`) — architecture validated

## Problem Statement

I often need to know when some part of a window changes — a CI badge turning red, a job count in a dashboard, a chat indicator, an upload progress bar finishing — without having to keep glancing at the window. Existing options (browser tab watchers, polling scripts, ad-hoc image-diff tools) either don't work when the window is hidden behind others, only work for web pages, or require enough setup per watch that I don't bother. The result is I tab-flip to babysit things and miss state changes I cared about.

## Solution

A macOS menu-bar app that watches a user-defined rectangle inside a chosen window for visual change and runs a shell command when a change is detected. The watcher works even when the target window is occluded, minimised, or on another Space. Multiple watchers run in parallel. All notification behaviour — banners, sounds, Slack pings, Pingbot, log lines — is outsourced to the shell hook, so the app itself ships no notification UI and the user composes whatever notification surface they already use.

A single per-watcher slider controls sensitivity, with sensible defaults. When a watcher fires it transitions to `triggered` and stays there until the user manually arms it again (capturing a fresh baseline) or deletes it — no recurring or cooldown mode (see `docs/adr/0001-single-post-fire-behaviour.md`). The app runs from the menu bar with no Dock presence.

## User Stories

**Configuration**

1. As a user, I want to pick a target window from a visual picker that highlights the window under my cursor, so I don't have to remember bundle IDs or window titles.
2. As a user, I want to draw a rectangle inside the chosen window with click-and-drag, so the watch region is exactly the area I care about and not the surrounding chrome.
3. As a user, I want the rectangle to be defined relative to the window (not the screen), so the watcher keeps working when I move or resize the window.
4. As a user, I want to give each watcher a human name, so I can recognise it in the popover and in hook env vars.
5. As a user, I want a single sensitivity slider per watcher with a sensible default, so I don't have to reason about ΔE thresholds.
6. As a user, I want to set a per-watcher capture interval (default 1 s, range 0.2–60 s) under an Advanced disclosure, so I can watch fast-moving regions more frequently and slow-moving ones less.
7. As a user, I want to write the shell command in a multi-line editor with a reference list of available env vars, so I can compose commands without consulting docs.
8. As a user, I want a "Test hook" button that invokes the command with synthetic env vars (including `WATCH_REASON=test-hook`), so I can verify my hook works before relying on it.
9. As a user, I want to "Save & Arm" or "Save (don't arm)" from the configure sheet, so I can stage a watcher without it firing immediately — and have that armed/idle choice persist across app restarts.

**Runtime / menu-bar**

11. As a user, I want a menu-bar icon I can left-click to see all my watchers in a popover, so the app stays out of my way until I want it.
12. As a user, I want each watcher tile to show a live thumbnail of the watched region, so I can see at a glance whether the watcher is still pointed at the right thing.
13. As a user, I want each tile to show a colour-coded state dot (idle=grey / armed=green / triggered=red / errored=⚠), so I can tell what each watcher is doing without reading text.
14. As a user, I want to right-click a tile to arm, pause, edit, delete, or run-hook-now, so common actions don't require opening a separate window.
15. As a user, I want a "+ New watcher" tile at the end of the grid, so adding a watcher is one click.
16. As a user, I want watchers to keep working when the target window is occluded, minimised, or on another Space, so I can use the app for windows I'm not actively looking at.
17. As a user, I want watchers to persist across app restarts including their armed/idle state, so the watchers I left running are still running tomorrow.
18. As a user, I want the menu-bar app to launch at login (optional), so my watchers resume automatically.

**Firing / hooks**

19. As a hook author, I want the watcher to invoke `/bin/sh -c <my command>` with `cwd=~` so I can pipe, redirect, and chain commands without escaping rules I don't expect.
20. As a hook author, I want a stable set of `WATCH_*` environment variables (name, ID, time, reason, score, threshold, sensitivity, post-fire mode, app bundle ID, window title, rect, thumb paths) so I can build any notification surface I want.
21. As a hook author, I want the path to a PNG of the watched region at fire time AND the baseline, so I can attach images to notifications.
22. As a hook author, I want my hook to be killed after 30 s if it hangs, so a misbehaving hook doesn't accumulate processes.
23. As a hook author, I want hook stdout/stderr captured to OSLog under `subsystem=com.bryce.pixelwatch, category=hook` (first ~4 KB of each stream), so I can debug a misbehaving hook via `log show --predicate 'subsystem == "com.bryce.pixelwatch"' --last 1h` without re-running it manually. (See `docs/adr/0002-hook-output-to-oslog-no-in-app-activity.md`.)
24. As a hook author, I want my hook's exit code to be logged but to never alter watcher state, so a hook failure doesn't silently disable the watcher.
25. As a user, I want a "window vanished" fire event (`WATCH_REASON=window-vanished` or `app-quit`) treated identically to a pixel-change event from the hook's perspective, so I can be notified when something I was watching disappears.

**Sensitivity behaviour**

26. As a user, I want the watcher robust to subpixel font rendering and anti-aliasing jitter at the default sensitivity, so I don't get spurious fires from cursor blinks or repainted text.
27. As a user, I want the watcher tolerant to whole-window repaints that don't change content (e.g. theme transitions, redraws), within reason — accepting that any algorithm has limits.

**Post-fire**

28. As a user, I want a fired watcher to enter `triggered` with a one-click Arm button to acknowledge it (which captures a fresh baseline and resumes watching), so I always know exactly which alerts I've seen.

**Errors / permissions**

30. As a user, I want the app to prompt for Screen Recording permission on first watcher creation, so I'm not blocked by a silent failure.
31. As a user, I want a clear error state on a watcher if its window can't be found AND the post-fire policy doesn't apply (e.g. permission revoked, capture stream failed), so I can distinguish "your window disappeared" from "the app is broken".
32. As a user, I want a "Re-check TCC permissions" button in Settings, so I can resolve a permissions issue without restarting the app.

**Debug surface**

33. As a power user, I want a unix-domain socket I can toggle on in Settings that emits every internal event as JSONL, so I can `nc -U bus.sock` and watch the app reason in real time.
34. As a power user, I want to push JSONL events into that same socket and have them indistinguishable from real events, so I can inject synthetic captures, force a fire, exercise post-fire logic, etc.
35. As a power user, I want to replay a recorded JSONL session with hooks suppressed (`--replay`), so I can regression-test the app on a captured trace without firing real commands.

**Settings**

36. As a user, I want a Settings window (not a popover) for app-wide preferences: debug socket on/off, default sensitivity, default tick interval (1 s default), launch-at-login, and version info.
37. As a user, I want my default sensitivity and default tick interval to pre-fill the new-watcher sheet, so I don't reconfigure the same defaults each time.

## Implementation Decisions

### Architecture: event-driven pipeline on a single bus

The app is built around an `EventBus` actor that broadcasts a typed `PixelWatchEvent` enum to all subscribers. Every stage of the pipeline (capture, diff, decide, hook, post-fire) is a function of shape `(AsyncStream<PixelWatchEvent>) -> AsyncStream<PixelWatchEvent>`, filtered to the events it cares about. The UI is also just a subscriber — it derives view state from the event stream rather than reading from stateful getters. Production wiring and the debug-socket replay surface use the exact same stages with no production/debug code fork.

The event enum:

```swift
enum PixelWatchEvent {
  case armed(watcherID: UUID, baseline: PixelBuffer)
  case frameCaptured(watcherID: UUID, frame: PixelBuffer, at: Date)
  case diffComputed(watcherID: UUID, score: Double, frame: PixelBuffer)
  case thresholdExceeded(watcherID: UUID, score: Double, frame: PixelBuffer)
  case windowVanished(watcherID: UUID, reason: VanishReason)
  case hookStarted(watcherID: UUID, command: String, reason: FireReason)
  case hookFinished(watcherID: UUID, exit: Int32, stdout: String, stderr: String)
  case paused(watcherID: UUID, reason: PauseReason)
  case errored(watcherID: UUID, error: Error)
}
```

Each event carries its `watcherID`; stages filter on subscribe.

### Modules

**Deep modules — testable in isolation:**

- **`Diff`** — pure function `(baseline, current, epsilon) -> Double`. Downsamples to max 256 px long edge, converts sRGB→linear-RGB via gamma 2.2 (vectorised with `vvpowsf` from Accelerate), computes per-pixel ΔE, returns fraction of pixels with ΔE > epsilon (epsilon fixed at 0.03 in v1; not user-facing). Ported directly from the bench (`Sources/pixelwatch-bench/Diff.swift`) — the vectorisation must be preserved.
- **`WatcherStateMachine`** — pure value type encoding the four-state diagram (`idle`/`armed`/`triggered`/`errored`). Method shape: `apply(event) -> (newState, [emittedEvents])`. No I/O, no async, no AppKit. Single source of truth for state transitions. Called by `WatcherStore`.
- **`WatcherStore`** — actor holding `[WatcherID: WatcherRuntimeState]` (state-machine state, current baseline while `armed`, latest frame and score). Subscribes to the bus on app launch; never unsubscribes. Calls `WatcherStateMachine.apply(event)` on each incoming event and re-emits derived events back to the bus. Stages query it for per-watcher state; the UI binds to it (SwiftUI observation). Single source of runtime truth. Does **not** hold a recent-activity ring buffer (see `docs/adr/0002-hook-output-to-oslog-no-in-app-activity.md`).
- **`HookRunner`** — `(command: String, env: [String: String], timeout: TimeInterval) async -> HookResult`. Wraps `Process` + pipes + a watchdog task that SIGTERMs after the timeout and SIGKILLs the process group if it doesn't exit. Captures stdout/stderr (capped at 4 KB per stream) and emits to OSLog under `subsystem=com.bryce.pixelwatch, category=hook`.
- **`Persistence`** — `[Watcher]` ⇄ JSON at `~/Library/Application Support/PixelWatch/watchers.json`. Atomic write via temp-file-and-rename. Codable types. Triggered on every persistence-affecting transition (Save, Delete, Arm, Pause) — no quit-time write, no debounce.
- **`EventBus`** — actor with `publish(_ event: PixelWatchEvent)` and `subscribe() -> AsyncStream<PixelWatchEvent>`. Hides multi-subscriber fan-out and `AsyncStream.Continuation` lifecycle (yield-and-finish-on-cancel semantics).

**Boundary modules — wrap OS APIs:**

- **`Capture`** — `(SCWindow, CGRect) async throws -> CGImage`. Wraps `SCScreenshotManager.captureImage`. The production version must handle display scale properly (the bench hard-codes `* 2`); pull scale from the relevant `NSScreen`.
- **`WindowResolver`** — `WindowBinding -> CGWindowID?`. Uses `CGWindowListCopyWindowInfo` only (no AX fallback in v1 — see CONTEXT.md). Resolution algorithm: try `windowIDHint` first; if stale, match by `(bundleID, titleMatch)`; if multiple candidates, prefer the one whose current bounds most overlap `lastKnownBounds`. If nothing matches, the calling stage triggers `errored`.
- **`Thumbnailer`** — `(CGImage, URL) -> Void` (writes PNG). Caches under `~/Library/Caches/PixelWatch/<watcher-id>/`.

**Stages — thin glue:**

- `CaptureStage` — runs one `Task` per `armed` watcher, looping `try await Task.sleep(for: .seconds(watcher.tickIntervalSeconds))` then capture. Task starts on transition into `armed`, cancels on transition out. Resolves window each tick; emits `windowVanished` if absent, else `frameCaptured`.
- `DiffStage` — on `frameCaptured`: reads the watcher's baseline from `WatcherStore`, computes score; emits `diffComputed`.
- `DecideStage` — applies the perception-linear `slider → threshold` mapping `threshold = 0.001 * 200^(1 - slider)` (slider=1 → 0.001 most sensitive, slider=0 → 0.2; default slider 0.7 → ≈ 0.005); emits `thresholdExceeded` when score crosses threshold.
- `HookStage` — on `thresholdExceeded` or `windowVanished` (and on `run-hook-now` / `test-hook` user actions): writes PNGs via `Thumbnailer`, invokes `HookRunner`; emits `hookStarted(reason:)` / `hookFinished`. In `--replay` mode the actual process spawn is suppressed but synthetic `hookStarted`/`hookFinished` events are still emitted so downstream observers see the full chain.

(There is no `PostFireStage`. The `thresholdExceeded → triggered` transition is handled by `WatcherStateMachine` via `WatcherStore` — see `docs/adr/0001-single-post-fire-behaviour.md`.)

**Debug surface:**

- `DebugSocket` — bidirectional JSONL bridge. Reads from clients: decode `PixelWatchEvent`, push to bus (indistinguishable from real events). Writes to clients: every bus event, JSON-encoded, one per line. Off by default; toggled in Settings; path `~/Library/Application Support/PixelWatch/bus.sock`.

**UI:**

- `MenuBarController` — `NSStatusItem` + `NSPopover` on left-click + app-delegate boilerplate. Subscribes to bus, derives `[WatcherViewState]` snapshot.
- `WatcherTileGrid` — SwiftUI view; 2-column scrollable grid of tiles + "+ New" tile + footer (⚙ Settings · Quit).
- `NewWatcherFlow` — coordinator that drives WindowPickerOverlay → RectPickerOverlay → ConfigureSheet, returning a `Watcher` to persist.
- `WindowPickerOverlay` — full-screen translucent `NSWindow`; highlights the window under the cursor using `CGWindowListCopyWindowInfo` + click-through hit-testing; click selects, `Esc` cancels.
- `RectPickerOverlay` — same overlay style, constrained to the chosen window's screen-bounds. Click-drag defines rect; `Esc` returns to window picker.
- `ConfigureSheet` — SwiftUI form: name field; sensitivity slider (no live preview — calibration is iterative; default slider 0.7); Advanced disclosure with tick-interval stepper (0.2–60 s, default 1.0 s); shell-command `TextEditor` with env-var token reference; "Test hook" button; "Save & Arm" / "Save (don't arm)" buttons.
- `SettingsWindow` — separate `NSWindow` with: debug socket on/off + path display, "Re-check TCC permissions" button, default sensitivity, default tick interval, launch-at-login toggle, About / version.

### Data model

```swift
struct Watcher: Codable {
  let id: UUID
  var name: String
  var target: WindowBinding
  var rect: CGRect            // window-relative, in points
  var sensitivity: Double     // 0.0…1.0
  var postFire: PostFireMode  // .autoPause or .cooldown(seconds: Double)
  var command: String
  var enabled: Bool
}

struct WindowBinding: Codable {
  var bundleID: String
  var titleMatch: TitleMatch  // .exact | .contains | .regex
  var ordinal: Int
}

enum PostFireMode: Codable {
  case autoPause
  case cooldown(seconds: Double)
}
```

Baseline `PixelBuffer`s are **not** persisted; they are re-captured on arm to sidestep stale-baseline issues across reboot/upgrade.

### State machine

The full state diagram is in the design doc. Six conceptual states: `idle` → `armed` → (`triggered` | `cooldown` | `errored`) with transitions driven by events. Every transition emits an event; the UI is a pure subscriber to those events.

### Hook contract

- Invoked via `/bin/sh -c "<command>"` with `cwd=~`.
- 30-second timeout, then SIGTERM, then SIGKILL the process group.
- stdout/stderr captured and made available in "Recent activity".
- Exit code logged but never alters watcher state.
- Env vars: `WATCH_NAME`, `WATCH_ID`, `WATCH_AT`, `WATCH_REASON`, `WATCH_SCORE`, `WATCH_THRESHOLD`, `WATCH_SENSITIVITY`, `WATCH_POST_FIRE`, `WATCH_WINDOW_APP`, `WATCH_WINDOW_TITLE`, `WATCH_RECT`, `WATCH_THUMB`, `WATCH_BASELINE_THUMB`. Full table in the design doc.

### Diff algorithm

Single fixed algorithm (no per-watcher choice):

1. Downsample cropped frame to max 256 px on long edge (bilinear via CoreGraphics).
2. Convert sRGB → linear-RGB via gamma 2.2 (vectorised with `vvpowsf`).
3. Per-pixel ΔE = Euclidean distance in linear-RGB.
4. `score = (count of pixels with ΔE > epsilon) / (total pixels)`, epsilon = 0.03.
5. Compare `score` to `threshold` derived from slider.

### Concurrency

Swift 6 strict concurrency is on. The bench established the working pattern (nonisolated worker funcs + actor-isolated state writers + Sendable structs at TaskGroup boundaries). Do not paper over with `@unchecked`; restructure. Specific known gotchas: `@main` cannot be used in a file named `main.swift`; `CVDisplayLink` crashes under Swift 6 (use `Timer.scheduledTimer` or `NSView.displayLink(target:selector:)`). Both documented in project `CLAUDE.md`.

### Persistence

JSON at `~/Library/Application Support/PixelWatch/watchers.json`, atomic write. PNG thumbnails at `~/Library/Caches/PixelWatch/<watcher-id>/`. No iCloud sync.

### Distribution

Signed and notarised standalone app, not App Store (avoids sandbox constraints on Screen Recording and shell commands).

## Testing Decisions

A good test for this app verifies **observable behaviour** — what events flow through the bus, what `score` a known-pair-of-images produces, what env vars a hook receives — not implementation details like which queue a task runs on or how an `AsyncStream` continuation is held. Tests should be readable as documentation of contracts.

The bench established a "no tests for throwaway tools" rule. The production app reverts to normal test discipline.

### Modules with tests

- **`Diff`** — golden-pair fixtures: (identical → score 0), (single-pixel change → score 1/N), (full-frame flip → score 1), (whitespace-aliased text edit → score below default threshold), (font-rendered "10" → "11" → score above default threshold). The exact scores are reference values, not just bounds — regressions in the algorithm should fail tests.
- **`WatcherStateMachine`** — exhaustive transition tests: from each state, feed each plausible event, assert resulting state and emitted events. Covers post-fire policy (auto-pause vs cooldown), window vanish, error injection, manual re-arm.
- **`HookRunner`** — real `/bin/sh` integration tests: success exit, non-zero exit, stdout/stderr capture, timeout behaviour (a hook sleeping past the timeout is killed), env vars present in subshell, no zombie processes after timeout.
- **`Persistence`** — round-trip `[Watcher]` through JSON; verify atomic write semantics (no partial file on simulated mid-write failure); verify schema-version handling for future migrations.
- **`EventBus`** — multi-subscriber fan-out (two subscribers both receive each event); subscriber cancellation doesn't deadlock the publisher; backpressure / buffering behaviour matches what stages need.

### Integration test

- **`DebugSocket`** round-trip — start the bus, open the socket, send a JSONL `frameCaptured` event, observe it broadcast to a subscriber. Doubles as a smoke test for the bus.
- **End-to-end stage chain on injected events** — assemble `EventBus + DiffStage + DecideStage + PostFireStage` (skip `CaptureStage` to avoid SCK dependency in CI; skip `HookStage` or use `/bin/true`); inject `frameCaptured` events from fixture PNGs; assert `thresholdExceeded` / `paused` / `rebaselined` emerge as expected. Replay-from-JSONL doubles as the regression-test format.

### Modules without tests

- **Stages** other than via the integration harness above. Stages are thin glue over deep modules; testing them in isolation duplicates work without catching real bugs.
- **`Capture` / `WindowResolver`** — both require a live window; covered by manual smoke-test against the running app rather than CI tests. The bench's continued working serves as informal regression for `Capture`.
- **UI views** (`MenuBarController`, `WatcherTileGrid`, `NewWatcherFlow`, the overlays, `ConfigureSheet`, `SettingsWindow`). Verified by running the app.

### Prior art

The bench code in `Sources/pixelwatch-bench/` is the closest existing reference for Swift 6 + AppKit/SCK patterns (concurrency, `TestWindow` lifecycle, `Capture` shape). Tests are new ground — no existing test target in the repo. The first test PR should establish the test target structure (likely `Tests/PixelWatchTests/`) and one passing test before fanning out.

## Out of Scope

- **Notification UI inside the app** — banners, sounds, badge counts on the menu-bar icon. All notification behaviour is shell-only.
- **Reference-image matching mode** — the only trigger is "differs from baseline".
- **"Stopped changing" / steady-state trigger.**
- **Screen-relative regions** — watch regions are always window-bound.
- **iCloud sync of watcher configs.**
- **Drag-to-reorder of watcher tiles.**
- **Watcher groups / folders.**
- **CLI tool** (`pixelwatch arm <name>` etc.) — the debug socket is the programmable surface.
- **Keyboard shortcuts** beyond standard popover dismissal.
- **Multi-rectangle / multi-region watchers** — one rectangle per watcher.
- **Watching screen regions outside any window** (e.g. menu bars, overlays).
- **Sandboxing / App Store distribution.**

## Further Notes

- **Implementation order** decided in brainstorming: backend tracer-bullet first (full bus + stages + hardcoded watcher, no UI), then UI layered on top. The first slice is the bus + all five stages + a hardcoded watcher proving the pipeline end-to-end.
- **Bench validates the architecture at intended scale.** CPU 0.006–0.019 % per watcher; p99 capture-to-diff latency 3–6 ms; RSS 58–80 MB at the typical 5–10 watcher range. No design changes blocked by bench results.
- **`Diff` ports verbatim from the bench**, including the `vvpowsf` vectorisation. The bench's `Diff.swift` is the production source; lift it.
- **Known design opens** (carried from design doc, not blocking implementation):
  - Slider→threshold mapping needs real-world calibration against stable-vs-changing windows.
  - Recent-activity log is in-memory ring buffer per watcher for v1; persistence deferred.
  - Multi-display window coordinates need verification — should "just work" with `SCContentFilter` but unverified.
- **TCC re-prompting** — if a different terminal/app launches the production app, Screen Recording permission may need to be re-granted. Surface this clearly on first launch.
- **Long-duration RSS behaviour** unverified — bench ran 60 s and observed +34 MB at N=50. Production app is intended to run 24/7; if certainty matters before shipping, run a longer bench or profile with Instruments.
