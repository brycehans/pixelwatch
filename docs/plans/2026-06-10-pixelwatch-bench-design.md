# PixelWatch — Benchmark CLI Design

**Date:** 2026-06-10
**Author:** Bryce (with Claude)
**Status:** Design accepted, pre-implementation
**Parent:** [2026-06-10-pixelwatch-design.md](2026-06-10-pixelwatch-design.md)

## Goal

A ~200-line Swift CLI that validates the design's capture+diff cost targets before any UI work:

- Idle watcher: < 1 % CPU each
- 20 watchers RSS: < 50 MB total
- 99p capture-to-diff latency: < 50 ms

If the numbers miss, the design changes (smaller downsample, batched capture, etc.) before UI.

## Package layout

```
pixelwatch/
├── Package.swift
├── Sources/
│   └── pixelwatch-bench/
│       ├── main.swift              # arg parsing, run loop, JSON output
│       ├── TestWindow.swift        # AppKit window: static half + animated half
│       ├── Capture.swift           # SCScreenshotManager wrapper
│       ├── Diff.swift              # downsample + ΔE, vImage/Accelerate
│       ├── Metrics.swift           # proc_pid_rusage, task_info for RSS
│       └── BenchRun.swift          # orchestrates N watchers, collects samples
└── docs/plans/...
```

- SwiftPM executable, `swift build -c release`. No Xcode project yet.
- Frameworks (system): AppKit, ScreenCaptureKit, Accelerate, Darwin.
- Deployment target: macOS 15.
- No external Swift packages. Hand-rolled arg parsing (~3 flags).

## Test window

Borderless AppKit window, 800×400, centred. Title `PixelWatch Bench`.

- **Left half (0,0,400,400):** solid mid-grey, never repaints. Idle-path workload.
- **Right half (400,0,400,400):** `CADisplayLink`-driven `CALayer` cycling hue at ~5 Hz. Active-path workload — guarantees non-zero diff scores.

`NSApplication.shared.run()` on the main thread; bench loop runs on a background `Task`. Window closes via `NSApp.terminate` when the bench completes.

## Watcher rect assignment

- Watchers `0…⌊N/2⌋`: rect = `(50, 50, 300, 300)` — fully inside static half.
- Watchers `⌈N/2⌉…N-1`: rect = `(450, 50, 300, 300)` — fully inside animated half.

Identical rects within a side: variance in latency is system noise, not workload skew.

## Run model

One process, N watchers. Each watcher is an `actor` holding its rect + baseline. A shared 1 Hz timer dispatches captures concurrently via `TaskGroup`.

**Per-tick per-watcher:**

1. `t0 = mach_absolute_time()`
2. `SCScreenshotManager.captureImage(contentFilter:, configuration:)` → `CGImage`
3. Crop to rect → downsample to 256 px long edge (vImage) → linear-RGB.
4. ΔE vs. baseline (vDSP), count pixels > ε (ε = 0.03 per parent design).
5. `t1 = mach_absolute_time()`; record `t1 - t0` as cycle latency.

**Process-level samples (1 Hz):**

- CPU%: `proc_pid_rusage(getpid(), RUSAGE_INFO_V6, &info)`; delta of `ri_user_time + ri_system_time` over the wall second.
- RSS: `task_info(mach_task_self(), MACH_TASK_BASIC_INFO, ...)` → `resident_size`.

**Run shape:**

- For each `N ∈ [1, 5, 20, 50]`:
  - 5 s warmup (discarded), 60 s measurement → 60 samples per watcher; 3000 cycle-latency samples at N=50.
- Output written to `bench-<unix>.json`.

## Output schema

```jsonc
{
  "startedAt": "2026-06-10T14:23:51+10:00",
  "host": { "os": "15.x", "cpu": "Apple M…", "cores": 10 },
  "runs": [
    {
      "n": 20,
      "warmupSec": 5,
      "durationSec": 60,
      "watchers": [
        { "id": 0, "side": "static",   "latencyMs": [12.3, 11.8, …] },
        { "id": 1, "side": "animated", "latencyMs": [14.1, 13.9, …] }
      ],
      "cpuPctSamples": [3.2, 3.4, …],
      "rssBytesSamples": [42_103_808, …],
      "errors": []
    }
  ]
}
```

Inspect with `fx`:

```sh
fx bench-*.json '.runs[].n + ": p99=" + Math.round(percentile(.runs[].watchers.flatMap(w => w.latencyMs), 99)) + "ms"'
```

## Failure handling

Fail fast, don't paper over:

- TCC Screen Recording denied → print one-line instruction, exit 1.
- `SCScreenshotManager.captureImage` throws → log watcher ID + error, drop that sample, continue. Recorded in `errors[]`.
- Test window never gains a `CGWindowID` within 2 s of `makeKeyAndOrderFront` → exit 1.

## CLI flags

| Flag | Default | Purpose |
|---|---|---|
| `--ns 1,5,20,50` | `1,5,20,50` | Comma list of N values to run. |
| `--duration 60` | `60` | Seconds of measurement per N. |
| `--warmup 5` | `5` | Seconds of warmup per N (discarded). |
| `--out bench-<unix>.json` | timestamp | Output path. |

## Explicit YAGNI

- No CSV output (JSON only; `fx` handles formatting).
- No per-watcher CPU attribution (process-level only; divide by N if needed).
- No comparison/diff mode (read two JSONs with `fx`).
- No attach-to-existing-window mode (own test window only).
- No `ArgumentParser` dependency.
