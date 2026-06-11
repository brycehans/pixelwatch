# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## PixelWatch

macOS menu-bar app that watches a user-defined rectangle inside a window for visual change and runs a shell command when it changes. Works even when the target window is occluded, minimised, or on another Space. Notifications are shell-only — the app ships no banner/sound UI.

## Authoritative docs

- **`CONTEXT.md`** — the project **glossary**. Source of truth for domain terms (Watcher, Arm/Pause/Fire, states, Baseline/Frame/Score, Sensitivity, WindowBinding, hook env vars). When in doubt about a name or semantics, read CONTEXT.md before grepping.
- **`docs/plans/YYYY-MM-DD-<topic>-design.md`** — accepted designs. One per artefact. Results sections get appended in-place, not split out.
- **`docs/plans/YYYY-MM-DD-<topic>-implementation.md`** — implementation plans alongside designs.
- **`docs/adr/`** — locked decisions worth re-reading before changing (e.g. `0001-single-post-fire-behaviour.md`, `0002-hook-output-to-oslog-no-in-app-activity.md`).

## Status

- **Production app:** running. Menu-bar `pixelwatch` executable with NSPopover grid UI, overlay-driven rect picker, Configure sheet, persistence, debug socket.
- **Bench CLI (`pixelwatch-bench`):** complete and effectively frozen. Its only production-bound primitive was the vectorised `Diff`, which has been ported into `PixelWatchCore`. Don't touch the bench unless re-validating perf.

## Layout

```
Package.swift                         # SwiftPM, tools-version 6.0, macOS 15, no external deps
Sources/
  PixelWatchCore/                     # headless pipeline + persistence; AppKit-free except CGWindow*
    EventBus.swift                    # actor; each subscribe() mints a fresh AsyncStream → independent fan-out
    Models.swift                      # Watcher, WindowBinding, TitleMatch, WatcherState, PixelWatchEvent (sans Codable)
    EventCodable.swift                # PixelBuffer + PixelWatchEvent Codable conformance (debug-socket wire format)
    Stages.swift                      # CaptureStage, DiffStage, DecideStage.start (extension), HookStage
    WatcherStateMachine.swift         # state machine + `enum DecideStage` (threshold formula lives here)
    WatcherStore.swift                # single long-lived actor; runtime snapshot (state + baseline + frame + score)
    WatcherArmService.swift           # idle→armed: resolve window + capture baseline + publish .armed
    Diff.swift                        # PixelBuffer type + vectorised linear-gamma diff (downscales to 256 long edge)
    Capture.swift                     # ScreenCaptureKit wrapper; scale derived per-capture from NSScreen overlap
    CGWindowCandidateProvider.swift   # CGWindowList → [WindowCandidate]
    WindowResolver.swift              # WindowBinding → CGWindowID (hint, then bundleID+title, then bounds overlap)
    HookRunner.swift                  # /bin/sh -c, env, 30s timeout, SIGTERM→SIGKILL pgroup, 4KB output cap
    DebugSocket.swift                 # ~/Library/Application Support/PixelWatch/bus.sock — JSONL bridge
    Persistence.swift                 # atomic write of watchers.json
  PixelWatchAppSupport/               # AppKit/SwiftUI surface; depends on Core (@_exported)
    PopoverGridView.swift                              # SwiftUI grid; cells + AddCell + empty state
    PopoverModel.swift                                 # @Observable @MainActor model; WatcherThumbnailItem
    URLCommandParser.swift                             # pixelwatch:// arm/pause/delete URL parser
    NewWatcherCoordinator.swift                        # focused-window → overlay → sheet → onCreated
    WatcherOverlayController.swift                     # AppKit overlay windows + WatcherOverlaySession protocol
    ConfigureWatcherSheet.swift                        # Configure sheet (name, sensitivity, command, Save vs Save & Arm)
    FocusedWindowProvider.swift, WindowSnapshot.swift  # frontmost-window resolution
    PixelBufferImage.swift                             # PixelBuffer.displayImage — linear→sRGB via vvpowsf, → NSImage
    OverlayAppearance.swift                            # state → NSColor + label text mapping
  pixelwatch/PixelWatchMain.swift     # @main app delegate; wires Bus + Store + Stages + UI + socket
  pixelwatch-bench/                   # validation CLI — see "Status"
Tests/
  PixelWatchCoreTests/                # pipeline, persistence, debug socket, state machine
  PixelWatchAppSupportTests/          # popover model, overlay controller, sheet/coordinator
docs/plans/, docs/adr/                # see "Authoritative docs"
docs/bench-results/                   # bench JSON (mostly gitignored)
```

## Architecture at a glance

It's an **event-sourced pipeline** behind a thin AppKit shell.

```
Capture ── frameCaptured ──► Diff ── diffComputed ──► Decide ── thresholdExceeded ──► Hook ── hookStarted/hookFinished
                                                                       │
                                                                       └─ windowVanished ──┘
                                                                                           │
        all events  ────────────────────────────────────────────────────────────────────► EventBus (actor, fan-out)
                                                                                           │
                                                                       WatcherStore (actor) ◄── applies events → runtime state
                                                                       NSApp delegate     ◄── drives popover, overlays, sheet
                                                                       DebugSocket        ◄──► JSONL clients
```

- **`EventBus`** is the only inter-stage channel. Each `subscribe()` call mints a fresh `UUID` + `AsyncStream`, so every subscriber (the 4 stages + `WatcherStore` + the app-delegate event monitor — 6 total today) gets its own independent iterator. `publish(_:)` does a `yield` on every continuation. No direct calls between stages.
- **`WatcherStore`** is the single source of truth for runtime state (current state, baseline, latestFrame, latestScore). UI and stages both query it; nobody else holds a per-watcher map. Caveat: because the store and the app-delegate's event monitor subscribe independently, there's a tiny race where a stage publishes an event and the delegate reads `store.state(for:)` before the store's own subscriber has applied it. There's a comment on `startEventMonitor` in `PixelWatchMain.swift` noting this; in practice the lag is invisible at the 4 Hz sync cadence.
- **Stages** are `enum`s with a `static func start(bus:store:) -> Task` returning a long-lived task per stage. Each stage owns whatever per-watcher sub-tasks it needs (`CaptureStage` spawns one capture loop per `armed` watcher).
- **`WatcherArmService.arm(…)`** is the only way to enter `armed`. It resolves the window, captures a baseline, and publishes `.armed(baseline:)`. There is no separate Re-arm — Arm covers idle/triggered/errored → armed.
- **`DebugSocket`** is bidirectional: outbound = every bus event as JSONL (with PixelBuffer payloads stripped to `{w,h,linearRGB:""}`); inbound = decoded as either `PixelWatchEvent` (re-published onto the bus) or `DebugCommand` (`newWatcher`, `quit`). Currently starts unconditionally — there's a TODO in `DebugSocket.swift` and `PixelWatchMain.swift` to gate it behind a Settings toggle before shipping.
- **`PixelWatchAppSupport`** depends on Core and `@_exported import`s it, so the executable only imports `PixelWatchAppSupport`.

### Runtime data lives in two places — know which
- **Persisted** (`watchers.json`): `Watcher` only (id, name, target, rect, sensitivity, tickIntervalSeconds, command, armed). Baselines, frames, scores, state-machine state are **never** persisted. At launch, every `armed: true` watcher gets re-armed (which re-captures a baseline); paused watchers come up `idle`.
- **In-memory** (`WatcherStore`): the runtime snapshot (state + baseline + latestFrame + latestScore). Rebuilt from scratch each launch.

### App startup wiring (PixelWatchMain.swift)
1. Create `EventBus`, then `WatcherStore(bus:)`, then `WatcherPersistence`.
2. Load watchers from disk → `store.add(_:)` each → `store.start()` (begins applying events).
3. Spawn the four stages: `CaptureStage`, `DiffStage`, `DecideStage`, `HookStage`.
4. Start the event-monitor task (drives overlay + popover refresh off bus events).
5. Restore overlays for any disk-loaded watcher whose target window is currently on screen.
6. Call `WatcherArmService.arm` for each disk-loaded `armed: true` watcher.

## Build & run

```sh
# Production app (menu-bar)
swift build
swift run pixelwatch                   # debug
swift build -c release && .build/release/pixelwatch
make bundle                            # creates/registers PixelWatch.app for pixelwatch:// URLs
open PixelWatch.app

# Bench CLI
swift build -c release
.build/release/pixelwatch-bench --out docs/bench-results/$(date +%Y-%m-%d).json

# Tests
swift test                                                            # all
swift test --filter PixelWatchCoreTests                               # one target
swift test --filter PixelWatchCoreTests.WatcherStateMachineTests      # one class
swift test --filter PixelWatchCoreTests.DiffTests/testIdenticalImagesScoreZero  # one method
```

Both executables require **Screen Recording TCC** for the terminal/app bundle running them. First launch prompts.

App-private data lives at `~/Library/Application Support/PixelWatch/` (`watchers.json`, `bus.sock`). Listed under `additionalDirectories` in `.claude/settings.local.json` so Read/Write don't require approval.

### URL scheme automation

The `pixelwatch://` scheme is registered through `Sources/pixelwatch/Info.plist`, so URL commands only work after running from the bundle built by `make bundle` / `open PixelWatch.app`. A bare `swift run pixelwatch` process is useful for debugging but is not registered with Launch Services.

```sh
open "pixelwatch://arm?id=<UUID>"
open "pixelwatch://pause?id=<UUID>"
open "pixelwatch://delete?id=<UUID>"
open "pixelwatch://show"
open "pixelwatch://hide"
```

`arm` delegates to `WatcherArmService.arm`, `pause` persists `armed=false` and publishes `.paused(reason: .userPaused)`, `delete` removes the watcher, and `show` / `hide` open or close the menu-bar popover. Use watcher IDs from `~/Library/Application Support/PixelWatch/watchers.json`.

## Conventions

- **CONTEXT.md is authoritative for naming.** Don't introduce synonyms — "Re-arm", "Trigger" (verb), "enable" are all explicitly banned there.
- **One design doc per artefact**, dated `YYYY-MM-DD-<topic>-design.md`. Implementation plans alongside as `…-implementation.md`. Append Results sections in-place.
- **Tests live where the code lives.** Pipeline / store / state-machine / persistence / socket tests in `PixelWatchCoreTests`. AppKit/SwiftUI surface tests in `PixelWatchAppSupportTests`. The bench CLI ships without tests by design.
- **Don't persist runtime state.** Baseline/Frame/Score are in-memory only — restart should rebuild them from scratch.
- **Intended scale:** ≤20 watchers, typically 5–10. RSS budget "unremarkable for a menu-bar app" (≲200 MB).

## Swift 6 gotchas (still apply)

- **Strict concurrency is on** (tools-version 6.0, no `swiftLanguageMode` override). Expect Sendable churn on AppKit/SCK boundaries. Don't paper over with `@unchecked` — restructure. The pattern that works: nonisolated worker funcs + actor-isolated state writers + explicit `Sendable` structs at TaskGroup / continuation boundaries.
- **`@main` can't live in a file named `main.swift`.** Swift 6 treats `main.swift` as implicitly top-level and rejects `@main`. The production executable uses `PixelWatchMain.swift` with `@main`; the bench uses top-level code in `main.swift`. Don't mix.
- **CVDisplayLink crashes under Swift 6.** The `@convention(c)` callback's hop to MainActor (via `DispatchQueue.main.async { MainActor.assumeIsolated { … } }`) fails an internal executor check on the IO thread. Use `Timer.scheduledTimer` or `NSView.displayLink(target:selector:)` instead. See `TestWindow.swift` in the bench for the Timer pattern; `PixelWatchMain.startSyncTimer` uses the same.
- **SCK capture honours window-frame × backing-scale-factor.** `Capture.swift` derives scale per-capture from `NSScreen.backingScaleFactor` weighted by overlap with the window frame. On a 1× display you get 1× output; on Retina you get 2×. Don't hard-code `* 2` like the old bench did.
- **AppKit objects aren't Sendable.** Use `@MainActor` for overlay/coordinator/session types. `WatcherOverlaySession` is `@MainActor` and `AnyObject`; the controller identifies sessions by reference.

## Working-environment notes (also in `~/Dev/CLAUDE.local.md`)

- **Commit messages MUST go via `tmp/commit-msg.txt` + `git commit -F`** — toolgate blocks heredocs and `$(…)` inside `-m`.
- **Every commit needs a `Claude-Session: <session_id>` trailer** after `Co-Authored-By` — SessionStart hook prints the session id.
- **Each `git` invocation is its own Bash call.** No chaining, no `git -C`.
- **Stage specific files**; never `git add .` / `-A`.
- **`curl` is blocked.** Use `xh` (HTTP) or `xhs` (HTTPS).
- **`sqlite3 -readonly`** is auto-allowed; omitting `-readonly` prompts.

## Useful one-liners

```sh
# Tail the debug bus (every event, JSONL):
nc -U ~/Library/Application\ Support/PixelWatch/bus.sock | fx .

# Trigger a new-watcher flow from outside the app:
echo '{"cmd":"newWatcher"}' | nc -U ~/Library/Application\ Support/PixelWatch/bus.sock

# Summarise a bench result file:
cat docs/bench-results/<file>.json | fx 'this.runs.map(r => { const ls = r.watchers.flatMap(w => w.latencyMs).sort((a,b)=>a-b); const p = (q) => ls[Math.floor(ls.length*q)]; const cpuMean = r.cpuPctSamples.reduce((a,b)=>a+b,0)/r.cpuPctSamples.length; return { n: r.n, p50ms: +p(0.5).toFixed(2), p99ms: +p(0.99).toFixed(2), cpuPerWatcherPct: +(cpuMean/r.n).toFixed(3), rssMaxMB: +(Math.max(...r.rssBytesSamples)/1048576).toFixed(1), errors: r.errors.length } })'

# Hook output (OSLog subsystem):
log show --predicate 'subsystem == "com.bryce.pixelwatch"' --last 1h

# All pixelwatch process logs (NSLog + AppKit noise) — use script to bypass shell quoting issues:
script -q /dev/null log show --last 15m --process pixelwatch 2>&1 | grep -v 'order window'

# Simulate a drag-to-create drop at screen coords (AppKit bottom-left origin):
echo '{"cmd":"dropAt","x":800,"y":600}' | nc -U ~/Library/Application\ Support/PixelWatch/bus.sock
```
