# PixelWatch — Design

**Date:** 2026-06-10
**Author:** Bryce (with Claude)
**Status:** Design accepted, pre-implementation

## Goal

A macOS menu-bar app that watches a user-defined rectangle inside a chosen window for visual change, and runs a shell command when a change is detected. Works even when the target window is occluded, minimised, or on another Space. Multiple watchers run concurrently. Notifications are entirely outsourced to shell hooks — the app ships no banner/sound UI of its own.

## Decisions

| Question | Decision |
|---|---|
| How is the watch region defined? | Pick a window, then draw a rect inside it (window-relative). |
| What triggers a notification? | Any change vs. baseline (single mode). |
| App shape? | Menu-bar resident, multiple persistent watchers. |
| Notification mechanism? | Shell-command hook only. |
| Sensitivity model? | Single per-watcher slider, sensible default. |
| Post-fire behaviour? | Per watcher: auto-pause OR cooldown-and-re-baseline. |
| Window disappearance? | Treated as a fire event (`WATCH_REASON=window-vanished`/`app-quit`), not a waiting state. |
| Sample cadence? | 1 Hz default, configurable in Advanced settings. |
| Diff algorithm? | One algorithm, no per-watcher choice. |
| Debug surface? | A single unix socket — inject and tail events as JSONL. |

## Stack

- **Language:** Swift 5.10+
- **UI:** AppKit (menu-bar `NSStatusItem` + `NSPopover`), SwiftUI inside the popover and sheets
- **Capture:** `ScreenCaptureKit.SCScreenshotManager` (macOS 14+; we target 15+ given the dev machine)
- **Window enumeration:** `CGWindowListCopyWindowInfo` for picking; Accessibility (`AXUIElement`) as a fallback for fidelity on Electron-style apps
- **Persistence:** JSON under `~/Library/Application Support/PixelWatch/`
- **Caches:** PNG thumbs under `~/Library/Caches/PixelWatch/<watcher-id>/`
- **Distribution:** Signed + notarised standalone app (not App Store)

### Required entitlements / permissions

- **Screen Recording** (TCC) — mandatory; prompted on first watcher creation
- **Accessibility** (TCC) — optional but recommended for better window metadata

## Architecture

Event-driven pipeline. Each stage consumes and produces events on a single typed bus. Production wiring uses real captures; tests and debug use the same stages with injected events. No production/debug code fork.

### Event model

```swift
enum PixelWatchEvent {
  case armed(watcherID: UUID, baseline: PixelBuffer)
  case frameCaptured(watcherID: UUID, frame: PixelBuffer, at: Date)
  case diffComputed(watcherID: UUID, score: Double, frame: PixelBuffer)
  case thresholdExceeded(watcherID: UUID, score: Double, frame: PixelBuffer)
  case windowVanished(watcherID: UUID, reason: VanishReason) // .windowClosed | .appQuit
  case hookStarted(watcherID: UUID, command: String)
  case hookFinished(watcherID: UUID, exit: Int32, stdout: String, stderr: String)
  case paused(watcherID: UUID, reason: PauseReason)
  case rebaselined(watcherID: UUID, baseline: PixelBuffer)
  case errored(watcherID: UUID, error: Error)
}
```

### Stages

Each stage is `(AsyncStream<PixelWatchEvent>) -> AsyncStream<PixelWatchEvent>`, filtered to the events it cares about.

- **`CaptureStage`** — timer-driven (default 1 Hz). On each tick: resolve `CGWindowID` from the watcher's `WindowBinding`; if missing, emit `windowVanished`; otherwise call `SCScreenshotManager.captureImage(...)`, crop to rect, emit `frameCaptured`.
- **`DiffStage`** — on `frameCaptured`: downsample to max 256px long edge, compute per-pixel ΔE in linear RGB vs. stored baseline, output `score = fraction of pixels with ΔE > epsilon` in `[0, 1]`. Emit `diffComputed`.
- **`DecideStage`** — on `diffComputed`: emit `thresholdExceeded` if `score > threshold(slider)`. (Threshold mapping: tentative `threshold = 0.02 + 0.18 * (1 - slider)` — slider=1 maps to threshold=0.02 [most sensitive], slider=0 to 0.20. Calibrate during benchmark.)
- **`HookStage`** — on `thresholdExceeded` or `windowVanished`: write PNGs to cache; spawn `/bin/sh -c <command>` with env vars (see below); 30s timeout; emit `hookStarted` / `hookFinished`.
- **`PostFireStage`** — on `hookFinished`: emit `paused` (auto-pause mode) or `rebaselined` (cooldown mode, after delay).

### The bus

One `EventBus` actor. Single global `AsyncStream<PixelWatchEvent>`. Every event carries its `watcherID`. Stages filter on subscribe. The UI (menu bar / popover) is also just a subscriber — it renders state from the event stream, never reads it from a stateful getter.

### Debug socket

`~/Library/Application Support/PixelWatch/bus.sock`. Off by default; toggle in Settings.

- **Writes from client** — JSONL `PixelWatchEvent` records decoded and pushed onto the bus, indistinguishable from real events. Allows injecting any event variant: synthetic `frameCaptured` from a fixture PNG, `thresholdExceeded` to test a hook without changing pixels, `hookFinished` to exercise post-fire policy, etc.
- **Reads from client** — every event the bus emits, JSON-encoded, one per line.

Recording is `nc -U bus.sock > session.jsonl`. Replay is `cat session.jsonl | nc -U bus.sock`. Replays optionally suppress `HookStage` (startup flag `--replay`) so they don't run real commands.

## Watcher data model

```swift
struct Watcher: Codable {
  let id: UUID
  var name: String            // "CI badge — main branch"
  var target: WindowBinding
  var rect: CGRect            // window-relative, in points
  var sensitivity: Double     // 0.0…1.0
  var postFire: PostFireMode  // .autoPause or .cooldown(seconds: Double)
  var command: String         // run via /bin/sh -c
  var enabled: Bool
}

struct WindowBinding: Codable {
  var bundleID: String
  var titleMatch: TitleMatch  // .exact | .contains | .regex
  var ordinal: Int            // disambiguator
}

enum PostFireMode: Codable {
  case autoPause
  case cooldown(seconds: Double)
}
```

Baseline buffers are **not** persisted; they're re-captured on arm. Sidesteps stale baselines across reboot/upgrade.

## State machine

```
              ┌──────┐
              │ idle │ (configured but not running, baseline absent)
              └──┬───┘
        arm      │
                 ▼
            ┌────────┐
            │ armed  │◄─────────────┐
            └───┬────┘              │ cooldown elapsed
                │                   │ + rebaseline
   threshold    │                   │
   exceeded     │                   │
   OR           │              ┌────┴─────┐
   window       ├──────────────► cooldown │ (postFire = .cooldown)
   vanished     │              └──────────┘
                │
                └──────────────►┌───────────┐
                                │ triggered │ (postFire = .autoPause)
                                └────┬──────┘
                                     │ user re-arms
                                     │
                                     ▼
                                  (armed)

   any ──user disables──► idle
   any ──permission revoked or stream failure──► errored
```

Each transition emits an event; the UI is a pure subscriber.

## UI

### Menu-bar popover (`NSPopover` on left-click)

Grid of watcher tiles (2 columns, scroll if many). Each tile:

- Live thumbnail (latest `frameCaptured` for armed/cooldown watchers; last-known with overlay for triggered/errored)
- State dot (armed=green, cooldown=amber+countdown, triggered=red, errored=⚠)
- Name underneath
- Right-click: Re-arm / Pause / Edit / Delete / Run hook now / Recent activity…

Last tile is "+ New watcher".

Footer: ⚙ Settings · Quit.

### New watcher flow

1. Popover dismisses on "+".
2. **Window picker overlay** — full-screen translucent overlay, window-under-cursor outlined, click to select.
3. **Rect picker** — same overlay, constrained to the chosen window's bounds. Click-drag to define rect. `Esc` returns to step 2.
4. **Configure sheet** — name; sensitivity slider with live diff preview against the just-captured baseline; post-fire mode (`autoPause` / `cooldown(N)`); shell command in a `TextEditor` with the env-var token reference; "Test hook" button; "Save & Arm" or "Save (don't arm)".

### Settings window (separate, not popover)

- Debug socket on/off (with path display)
- Re-check TCC permissions
- Default sensitivity / default post-fire mode (pre-fills new-watcher sheet)
- Capture cadence (default 1 Hz, advanced)
- Launch at login
- About / version

## Diff algorithm

Single fixed algorithm:

1. Downsample the cropped frame to max 256 px on the long edge (bilinear).
2. Convert both baseline and current to linear-RGB (gamma 2.2 → linear).
3. For each pixel, compute ΔE = Euclidean distance in linear-RGB.
4. `score = (count of pixels with ΔE > epsilon) / (total pixels)`.
5. `epsilon` is a fixed small constant (e.g. 0.03 in linear-RGB units). Robust to font subpixel rendering and anti-aliasing.
6. Compare `score` to per-watcher `threshold` derived from the slider.

## Hook env vars

When a watcher fires, the command is invoked via `/bin/sh -c "<command>"` with `cwd=~`, 30 s timeout, stdout/stderr captured.

| Var | Type | Example | Purpose |
|---|---|---|---|
| `WATCH_NAME` | string | `CI badge — main` | Human name. |
| `WATCH_ID` | UUID | `2f9b1c8e-…` | Stable ID for dedup. |
| `WATCH_AT` | ISO-8601 | `2026-06-10T14:23:51+10:00` | Trigger time. |
| `WATCH_REASON` | enum | `pixel-change` \| `window-vanished` \| `app-quit` | Why it fired. |
| `WATCH_SCORE` | float `0…1` | `0.42` | Diff score (0 for vanish). |
| `WATCH_THRESHOLD` | float `0…1` | `0.10` | Threshold that was crossed (empty for vanish). |
| `WATCH_SENSITIVITY` | float `0…1` | `0.65` | Raw slider value as set by user. |
| `WATCH_POST_FIRE` | enum | `auto-pause` \| `cooldown:30` | Post-fire mode. |
| `WATCH_WINDOW_APP` | string | `com.tinyspeck.slackmacgap` | Bundle ID. |
| `WATCH_WINDOW_TITLE` | string | `#general — KO Group` | Window title at fire time (last-known if vanished). |
| `WATCH_RECT` | string | `120,80,400,60` | Window-relative rect `x,y,w,h` in points. |
| `WATCH_THUMB` | abs path | `…/<id>/fire-2026-06-10T14-23-51Z.png` | PNG at trigger moment. |
| `WATCH_BASELINE_THUMB` | abs path | `…/<id>/baseline.png` | PNG of baseline. |

Hook exit code is logged but never alters watcher state.

### Example hooks

**Pingbot:**
```sh
ping "$WATCH_NAME changed ($WATCH_REASON)" --image "$WATCH_THUMB"
```

**Slack webhook:**
```sh
xhs POST hooks.slack.com/services/T.../B.../xxx \
  text="🔔 $WATCH_NAME changed at $WATCH_AT (score=$WATCH_SCORE)"
```

**macOS notification:**
```sh
osascript -e "display notification \"$WATCH_NAME ($WATCH_REASON)\" with title \"PixelWatch\" sound name \"Glass\""
```

**Activity log for tuning:**
```sh
echo "$WATCH_AT $WATCH_NAME $WATCH_REASON score=$WATCH_SCORE thr=$WATCH_THRESHOLD sens=$WATCH_SENSITIVITY" \
  >> ~/pixelwatch-fires.log
```

## Tests

Each stage is a function on `AsyncStream`s, so unit tests feed a hand-built input stream and assert on the output stream. No mocking of `SCScreenshotManager` or the file system.

Replay-from-JSONL doubles as an integration test format: a curated `fixtures/*.jsonl` of recorded sessions becomes a regression test suite.

## Pre-implementation step — benchmark

Before building UI, write a ~200-line CLI that:

1. Spins up N watchers (N = 1, 5, 20, 50) on a real visible window.
2. Captures + diffs at 1 Hz on each.
3. Measures CPU% (via `proc_pid_rusage`), RSS, per-cycle latency.

Target numbers:

- Idle watcher (no pixel change): < 1 % CPU each
- 20 watchers RSS: < 50 MB total
- 99p capture-to-diff latency: < 50 ms

If we miss these, the design changes (smaller downsample, batched capture, etc.) before any UI work begins.

## Open questions

- **Slider → threshold mapping** — tentative formula above; pin down during benchmark when we can see real-world score distributions for stable vs. changing windows.
- **Recent-activity log on disk** — keep in-memory ring per watcher for v1; persist later if useful.
- **Multi-display window-coordinate math** — sanity check that `SCScreenshotManager` returns sensible pixels for windows on secondary displays. Should "just work" with `SCContentFilter`, but verify.

## Explicit YAGNI (v1)

- No notification UI (shell hook only)
- No reference-image matching mode
- No "stopped changing" trigger
- No screen-relative regions (window-bound only)
- No iCloud sync of watcher configs
- No drag-to-reorder of watcher tiles
- No watcher groups / folders
- No CLI for `pixelwatch arm <name>` etc. (the socket is the programmable surface)
- No keyboard shortcuts beyond standard popover dismissal
