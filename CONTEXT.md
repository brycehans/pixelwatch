# PixelWatch

Menu-bar app that watches a window rectangle and runs a shell command when its pixels change. This document is the project glossary; implementation details and decisions live in `docs/plans/` and (when warranted) `docs/adr/`.

## Language

### Lifecycle

**Watcher**:
The configured unit — a named binding from {window, rect, sensitivity, post-fire mode, command mode} to a runtime instance. Persisted as JSON. Command mode is one of `shell`, `notification`, or `webhook`.

**Arm**:
The user action (and event) that brings a Watcher into the `armed` state. Captures a fresh baseline. There is no separate "Re-arm" verb — "Arm" is the only label for the idle/triggered/errored → armed transition.
_Avoid_: Re-arm, enable, start.

**Pause**:
The user action that takes an armed Watcher to `idle`. Emits `paused(reason: .userPaused)`.
_Avoid_: Disable, stop.

**Fire**:
The moment a Watcher decides it should invoke its hook — i.e. `thresholdExceeded` or `windowVanished`. A Watcher *fires*; the hook *runs*. After firing, the Watcher is always in `triggered` — there is no recurring/cooldown mode. The only ways out of `triggered` are user Arm (captures a new baseline) or delete.
_Avoid_: "Trigger" as a verb. Reserve `triggered` for the state name.

### Watcher states

Four states, no more:

- **`idle`** — saved but not running. No baseline held. Grey dot in the grid.
- **`armed`** — running. Capturing frames each tick, diffing against baseline. Green dot.
- **`triggered`** — fired; waiting for user to Arm again (which captures a new baseline) or delete. Red dot.
- **`errored`** — capture or permission failure. ⚠ dot. Recovery is "Arm" (same verb as idle→armed).

`paused` is an *event*, not a state — it marks the `armed → idle` transition.

There is no `cooldown` state and no recurring mode. A fired Watcher stays `triggered` until the user acts. This trades automation for predictability — every fire is an acknowledgement, never a notification storm.

### Debug surface

**Debug socket**:
A bidirectional JSONL bridge on a Unix domain socket at `~/Library/Application Support/PixelWatch/bus.sock`. Off by default; toggled in Settings. Reads from clients = bus events serialised one-JSON-per-line; writes from clients = JSONL records decoded as `PixelWatchEvent` and pushed onto the bus, indistinguishable from real events. The socket is the only programmable surface for the app — there is no CLI.

**URL command**:
An external command delivered through the registered `pixelwatch://` URL scheme. Supported actions are watcher commands `arm`, `pause`, and `delete`, each with an `id=<Watcher UUID>` query parameter, plus popover commands `show` and `hide` with no query parameters. URL commands are for user automation tools such as BetterTouchTool, Raycast, and shell scripts. They require the app to be launched from the `PixelWatch.app` bundle so Launch Services has registered the scheme.

**Replay**:
The mode invoked via `--replay <file>` (CLI flag at app launch) that suppresses `HookStage`'s actual process spawning so a recorded `.jsonl` session can be re-run against the app without re-triggering real hooks. `HookStage` still emits `hookStarted` / `hookFinished` events with synthetic values so downstream observers see the full event chain.

### Persistence

**Save**:
Atomic write of all Watchers to `~/Library/Application Support/PixelWatch/watchers.json` (temp file + rename). Triggered on every persistence-affecting transition: Configure-sheet save, Delete, Arm (sets `armed=true`), Pause (sets `armed=false`). No quit-time write. No debouncing — ≤20 watchers in a ≲10 KB file is cheap. Baselines and runtime state (Frame, Score, state-machine state beyond `armed: Bool`) are never persisted.

**Save & Arm vs Save (don't arm)**:
Both Configure-sheet buttons write the Watcher to disk. "Save & Arm" sets `armed=true` and transitions `idle → armed` immediately (capturing baseline). "Save (don't arm)" sets `armed=false`; the Watcher exists but will not auto-arm at this app launch or any future launch until the user arms it manually.

**Errored recovery**:
Manual only — the user clicks Arm on the errored tile. We re-attempt window resolution + baseline capture; on success → `armed`, on failure → still `errored` (possibly with an updated error message). No auto-retry, no app-launch observers. Silent recovery would disguise real failure modes.

### Hooks

**Hook**:
The action a Watcher takes when it fires. Three modes:

- **Shell**: runs `/bin/sh -c "<command>"`, `cwd=~`, **fixed 30 s timeout** (no per-watcher knob in v1 — slow hooks should detach themselves with `(slow-thing &) ; exit 0`), SIGTERM then SIGKILL the process group.
- **Notification**: posts an OS notification via `terminal-notifier`.
- **Webhook**: sends `POST <url>` with a JSON body containing the hook environment variables (see README). **10 s timeout.** Exit 0 for 2xx, exit 1 for non-2xx, exit 127 for network errors.

Exit code is logged but never alters Watcher state. No coalescing across Watchers — N simultaneous fires spawn N actions.

**Hook output**:
stdout and stderr are captured and emitted to OSLog under `subsystem=com.bryce.pixelwatch, category=hook` (tag: watcher name + exit code + first ~4 KB of each stream). User finds it via `log show --predicate 'subsystem == "com.bryce.pixelwatch"' --last 1h`. There is no in-app UI for hook output.

**WATCH_REASON**:
Enum value passed in the hook environment. Five values:

- `pixel-change` — score crossed threshold while armed.
- `window-vanished` — watched window closed, owning app still running.
- `app-quit` — owning app exited.
- `run-hook-now` — user picked "Run hook now" from the tile's right-click menu.
- `test-hook` — Configure-sheet "Test hook" button.

Hook authors should distinguish user-initiated fires (`run-hook-now`, `test-hook`) from real ones — typically by short-circuiting Slack pings.

### Window targeting

**WindowBinding**:
The persistent reference from a Watcher to "the window this watches". Three fields: `bundleID`, `titleMatch` (one of `.exact` | `.contains` | `.regex`; defaults to `.exact`), and a `windowIDHint: CGWindowID?` + `lastKnownBounds: CGRect?` cached at last successful resolution. The positional `ordinal: Int` from the original design is dropped — it's unstable across app restarts.

**Resolve**:
The act of turning a `WindowBinding` into a live `CGWindowID` for capture. Algorithm: try the cached `windowIDHint` first; if stale, match by `(bundleID, titleMatch)`; if multiple candidates, prefer the one whose current bounds most overlap `lastKnownBounds`. If nothing matches → Watcher transitions to `errored`.

### Runtime state

**WatcherStore**:
The single long-lived actor that holds runtime state for every Watcher: state-machine state (`idle`/`armed`/`triggered`/`errored`), the current Baseline (only while `armed`), and the latest Frame and Score. Subscribes to the bus on app launch and never unsubscribes. Calls `WatcherStateMachine.apply(event)` on each incoming event and re-emits any derived events back to the bus.

The store does **not** hold a recent-activity ring buffer. Recent activity is the user's concern — their hook can append to a log file (the design doc shows the `~/pixelwatch-fires.log` pattern).

Stages query the store for per-watcher state they need (`DiffStage` asks for the current Baseline; `CaptureStage` asks for the cached `windowIDHint` + `lastKnownBounds`). Stages do not hold per-watcher maps of their own.

The UI binds to the store, not directly to the bus — SwiftUI sees a stable observable projection, not raw event flow.

### Pixels

**Baseline**:
The `PixelBuffer` captured at the moment a Watcher is armed. All future frames diff against it until the Watcher fires (→ `triggered`) and the user arms it again (capturing a fresh baseline). Baselines are never updated mid-`armed`.

**Frame**:
A single captured `PixelBuffer` for a Watcher tick.

**Tick**:
One capture-diff-decide cycle for a single Watcher. Each Watcher ticks at its own `tickIntervalSeconds` (per-watcher field, default 1.0 s, bounds 0.2 s – 60 s). The Settings "Default cadence" pre-fills the field for new Watchers; there is no global tick. `CaptureStage` runs one `Task` per `armed` Watcher.

**Score**:
The Diff output: fraction of pixels (0…1) whose ΔE exceeds `epsilon`. Per `frameCaptured` event.

**Sensitivity**:
The user-facing slider value (0…1). Maps to a `threshold` via the perception-linear formula `threshold = 0.001 * 200^(1 - slider)` — slider=1 → 0.001 (any single pixel changed), slider=0 → 0.2 (20% of pixels). Default slider value is **0.7 → threshold ≈ 0.005** (≈ 0.5 % of pixels) — biased deliberately toward sensitive so the common case works without tuning. Reference points: slider=0.5 → 0.014 (1.4 %); slider=0.3 → 0.048 (4.8 %).

**Threshold**:
The numeric cutoff `score` must cross to fire. Derived from `sensitivity`; not user-facing directly.

**Epsilon**:
The per-pixel ΔE cutoff inside `Diff` — pixels with ΔE > epsilon count toward the score. Fixed at 0.03 (linear-RGB). Not user-facing in v1; calibrated to reject anti-aliasing and subpixel-text noise.

## Relationships

- A **Watcher** has exactly one **WindowBinding** and one rect.
- An **Arm** action captures a new **Baseline**. A **Baseline** lives for exactly one armed→triggered cycle.
- **Fire** is the verb; **triggered** is the state name. They're not synonyms.

## Example dialogue

> **Dev:** "If a CI badge goes red and stays red, do we keep firing?"
> **PM:** "No. We fire once, the Watcher goes to `triggered`, and that's it until the user arms it again. Every fire is an acknowledgement, not a stream."

> **Dev:** "What about the user hitting Pause on a triggered watcher?"
> **PM:** "Pause goes to `idle`. From `triggered`, the natural action is Arm — but Pause is still valid; it just means 'acknowledge and leave it off'."

## Flagged ambiguities

- ~~"Re-arm" vs "Arm"~~ — resolved: only "Arm".
- ~~`enabled: Bool` on `Watcher` vs `idle` state~~ — resolved: drop `enabled`; persist desired state as `armed: Bool`. At app launch, every previously-armed watcher re-captures its baseline and comes up `armed`; previously-paused watchers come up `idle`. Pause and Arm both persist across restarts.
- ~~"Trigger" as verb vs state~~ — resolved: *fire* is the verb, *triggered* is the state.
- ~~`PostFireMode.autoPause` vs `.cooldown(N)`~~ — resolved: dropped. There is only one post-fire behaviour — go to `triggered` and wait for the user. No recurring/cooldown mode in v1; no `rebaselined` event; no `PostFireStage` beyond emitting the state transition; no `WATCH_POST_FIRE` env var.
- ~~`WindowBinding.ordinal: Int`~~ — resolved: dropped. Replaced with `windowIDHint: CGWindowID?` + `lastKnownBounds: CGRect?`. Positional ordinals are unstable across restarts and silently re-bind to the wrong window when a second match appears.
- ~~Accessibility (`AXUIElement`) fallback for Electron-style apps~~ — resolved: cut from v1. Re-introduce only if a specific target app forces it. Window picker shows only what `CGWindowListCopyWindowInfo` sees; minimised windows are filtered out of the picker.
- ~~In-app "Recent activity" view + per-watcher ring buffer~~ — resolved: cut from v1. Users log via their own hook (e.g. `echo … >> ~/pixelwatch-fires.log`). Drops the right-click "Recent activity…" menu item, drops the in-memory buffer in `WatcherStore`. Hook stdout/stderr is captured to OSLog (see Hooks).
- ~~Live diff preview in Configure sheet (PRD story 6)~~ — resolved: cut from v1. The sheet has a sensitivity slider with no live feedback; calibration is iterative ("Save & Arm", observe whether it fires when it shouldn't, Edit and adjust). Saves the cost of continuous SCK capture during configuration. Slider default 0.7 is biased high enough that most use cases work without tuning.
