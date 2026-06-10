# PixelWatch

macOS menu-bar app that watches a user-defined rectangle inside a window for visual change and runs a shell command when it changes. Works even when the target window is occluded, minimised, or on another Space. Notifications are shell-only — the app ships no banner/sound UI.

## Status

- **Parent design:** `docs/plans/2026-06-10-pixelwatch-design.md` — accepted.
- **Benchmark CLI:** complete (`pixelwatch-bench`). Validated architecture (CPU, latency); see Results section in the bench design doc. Production app not yet started.
- **Production app:** not yet started. Next step is brainstorming the implementation order, probably starting with the event-bus + stages skeleton, then capture, then UI.

## Layout

```
docs/plans/                          # design docs (one per artefact, dated)
docs/bench-results/                  # bench JSON outputs (gitignored except 2026-06-10-default.json)
Package.swift                        # SwiftPM, tools-version 6.0, macOS 15, no external deps
Sources/pixelwatch-bench/            # the bench CLI (throwaway-ish; Diff is the only production-bound primitive)
  main.swift                         # top-level entry — NOT @main struct (see "Gotchas" below)
  Diff.swift                         # vectorised gamma + ΔE — gets ported to production DiffStage
  Metrics.swift                      # proc_pid_rusage + task_info wrappers
  Capture.swift                      # SCScreenshotManager wrapper
  TestWindow.swift                   # @MainActor bench-only test window
  BenchRun.swift                     # bench orchestrator
```

## Build & run

```sh
swift build -c release
.build/release/pixelwatch-bench --out docs/bench-results/$(date +%Y-%m-%d).json
```

Default flags: `--ns 1,5,20,50 --duration 60 --warmup 5` → ~5 min wall time. Spawns a borderless 800×400 test window during the run.

Requires **Screen Recording TCC** granted to the terminal running the bench. First run prompts.

## Conventions

- **No tests for throwaway tools.** The bench CLI ships without tests; its JSON output is the validation. When the `Diff` algorithm is ported to the production app, write tests *there*, not in the bench.
- **Intended scale:** ≤20 watchers, typically 5–10. RSS budget is "unremarkable for a menu-bar app" (≲200 MB at the intended scale), not the speculative 50 MB the original design listed.
- **One design doc per artefact**, dated `YYYY-MM-DD-<topic>-design.md`. Implementation plans live alongside as `YYYY-MM-DD-<topic>-implementation.md`. Results sections get appended to the design doc, not split out.

## Gotchas hit during the bench (apply when starting the production app)

- **Swift 6 strict concurrency is on** (tools-version 6.0, no explicit `swiftLanguageMode`). Expect Sendable churn on AppKit/SCK boundaries. Don't paper over with `@unchecked` — restructure instead. The bench's `BenchRun.swift` shows a working pattern (nonisolated worker funcs + actor-isolated state writers + explicit Sendable structs at TaskGroup boundaries).
- **`@main` cannot be used in a file named `main.swift`.** Swift 6 treats `main.swift` as implicitly top-level and rejects `@main`. Use top-level code in `main.swift` (Swift 6 supports `await` at top level there) OR name the file something else and use `@main`. See `Sources/pixelwatch-bench/main.swift` for the pattern.
- **CVDisplayLink crashes under Swift 6.** The `@convention(c)` callback's hop back to MainActor (via `DispatchQueue.main.async { MainActor.assumeIsolated { ... } }`) fails an internal executor check on the IO thread. Use `Timer.scheduledTimer` or `NSView.displayLink(target:selector:)` instead. See `TestWindow.swift` for the Timer pattern.
- **SCK capture is at @2x by default** (or display scale). `Capture.swift` hard-codes `* 2` for `SCStreamConfiguration.width/height`. On a 1x display this will scale up unnecessarily; on a Retina display it matches. Revisit when targeting non-Retina users.

## Working-environment notes (also in `~/Dev/CLAUDE.local.md`)

- Commit messages MUST go via `tmp/commit-msg.txt` + `git commit -F` — toolgate blocks heredocs / `$(...)` inside `-m`.
- Every commit needs a `Claude-Session: <session_id>` trailer after `Co-Authored-By` — the SessionStart hook prints the session id.
- Each `git` invocation is its own Bash call. No chaining, no `git -C`.
- Stage specific files; never `git add .` / `-A`.

## Useful commands

```sh
# Summarise a bench result file:
cat docs/bench-results/<file>.json | fx 'this.runs.map(r => { const ls = r.watchers.flatMap(w => w.latencyMs).sort((a,b)=>a-b); const p = (q) => ls[Math.floor(ls.length*q)]; const cpuMean = r.cpuPctSamples.reduce((a,b)=>a+b,0)/r.cpuPctSamples.length; return { n: r.n, p50ms: +p(0.5).toFixed(2), p99ms: +p(0.99).toFixed(2), cpuPerWatcherPct: +(cpuMean/r.n).toFixed(3), rssMaxMB: +(Math.max(...r.rssBytesSamples)/1048576).toFixed(1), errors: r.errors.length } })'
```
