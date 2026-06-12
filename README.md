# PixelWatch

https://github.com/user-attachments/assets/66f02c05-9039-4eac-92c9-5e07cc9fa1ff

--------

A tiny Mac app that watches a rectangle inside another app's
window and pings when the pixels change. A ping can post an OS notification, run a shell command, or fire a webhook.

This makes it useful for watching CI badges, dashboards, queues, build status panels, 
or any visual state that does not already have a better API.

Use it in Agentic workflows to be notified of state changes in external systems,
or pass the resulting screenshot into an OCR or vLLM to diff the old and new content.

## Requirements

- macOS 15 or newer.
- Swift 6 toolchain.
- Screen Recording permission for the terminal or `PixelWatch.app` bundle that
  launches the app.
- `terminal-notifier` if you use the built-in notification mode. Shell-command
  mode does not require it.

## Build And Run

For local development:

```sh
swift build
swift run pixelwatch
```

For normal use, build and register the app bundle:

```sh
make bundle
open PixelWatch.app
```

The bundle matters for `pixelwatch://` URL automation because macOS Launch
Services registers URL schemes from app bundles, not from a bare `swift run`
process.

Useful make targets:

```sh
make build    # release build
make bundle   # build PixelWatch.app and register it
make run      # build/register/open PixelWatch.app
make clean    # remove .build and PixelWatch.app
```

## Usage Guide

### 1. Grant Screen Recording

On first launch, macOS may ask for Screen Recording permission. Grant it to the
thing that launched PixelWatch:

- `Terminal`, `iTerm`, or your IDE if you run `swift run pixelwatch`.
- `PixelWatch.app` if you run the bundled app.

If capture fails after granting permission, quit PixelWatch and launch it again.

### 2. Create A Watcher

1. Open the target window you want to watch.
2. Click the `PW` menu-bar item.
3. Drag the dashed `+` tile from the popover onto the target window.
4. Release the tile over the area you want to watch.
5. In the configuration sheet, choose:
   - `Notification` to post a PixelWatch notification.
   - `Run a command` to run a shell command through `/bin/sh -c`.
   - `Webhook` to POST a JSON payload to a URL.
6. Adjust sensitivity if needed.
7. Click `Save & Arm` to start watching immediately, or `Save` to keep the
   watcher idle.

The watched rectangle is persisted relative to the target window. PixelWatch
uses the target app bundle ID, window title, cached window ID, and last-known
bounds to resolve the same window again later.

### 3. Read Watcher State

The popover shows one row per watcher:

- `IDLE`: saved but not currently watching.
- `ARMED`: actively capturing and diffing against a baseline.
- `TRIGGERED`: fired once and waiting for you to arm it again or delete it.
- `ERRORED`: capture, permission, or window-resolution failed.

Rows show the baseline thumbnail (`B`) and latest frame thumbnail (`F`) when
available. Triggered and errored watchers show an arm button. Every row has a
delete button.

### 4. Arm, Pause, Delete

From the UI:

- Use `Save & Arm` when creating a watcher to capture a fresh baseline and begin
  watching.
- Use the arm button on a triggered or errored watcher to capture a new baseline.
- Use the row delete button to remove a watcher.
- Use the gear menu to quit PixelWatch.

From automation, use the URL scheme documented below.

## Sensitivity

Sensitivity is a `0...1` slider. Higher values fire on smaller changes. Lower
values tolerate more pixel movement before firing.

Internally, PixelWatch compares each frame against the baseline captured when
the watcher was armed. If the fraction of changed pixels crosses the derived
threshold, the watcher fires and moves to `triggered`.

If a watcher fires too eagerly, lower the sensitivity. If it misses real
changes, raise the sensitivity and arm it again.

## Shell Commands

Shell-command mode runs:

```sh
/bin/sh -c "<your command>"
```

The process starts in your home directory, inherits the PixelWatch process
environment, and is stopped after 30 seconds. PixelWatch sends SIGTERM to the
process group first, then SIGKILL if it does not exit promptly.

Available environment variables:

| Variable | Meaning |
| --- | --- |
| `WATCH_ID` | Stable watcher UUID. |
| `WATCH_AT` | ISO-8601 fire time. |
| `WATCH_REASON` | `pixel-change`, `window-vanished`, or `app-quit`. |
| `WATCH_SCORE` | Diff score from `0` to `1`; `0` for vanished windows. |
| `WATCH_THRESHOLD` | Threshold crossed for pixel changes; empty for vanished windows. |
| `WATCH_SENSITIVITY` | Raw sensitivity slider value. |
| `WATCH_WINDOW_APP` | Target app bundle ID. |
| `WATCH_WINDOW_TITLE` | Target window title match text. |
| `WATCH_RECT` | Watched rectangle as `x,y,width,height` in window-relative points. |
| `WATCH_THUMB` | Reserved; currently empty. |
| `WATCH_BASELINE_THUMB` | Reserved; currently empty. |

Example command that appends a local log:

```sh
echo "$WATCH_AT $WATCH_WINDOW_TITLE $WATCH_REASON score=$WATCH_SCORE" >> ~/pixelwatch-fires.log
```

Example command that posts a macOS notification with AppleScript:

```sh
osascript -e "display notification \"$WATCH_WINDOW_TITLE changed ($WATCH_REASON)\" with title \"PixelWatch\""
```

Hook stdout and stderr are captured to OSLog, not shown in the app:

```sh
log show --predicate 'subsystem == "com.bryce.pixelwatch"' --last 1h
```

## Webhook

Webhook mode sends an HTTP `POST` to a URL when a watcher fires. The request
body is a JSON object containing the same data as the shell-command environment
variables:

```json
{
  "WATCH_ID": "...",
  "WATCH_AT": "...",
  "WATCH_REASON": "pixel-change",
  "WATCH_SCORE": "0.42",
  "WATCH_THRESHOLD": "0.005",
  "WATCH_SENSITIVITY": "0.7",
  "WATCH_WINDOW_APP": "com.example.app",
  "WATCH_WINDOW_TITLE": "Window Title",
  "WATCH_RECT": "x,y,width,height"
}
```

The request includes `Content-Type: application/json`. PixelWatch waits up to
10 seconds for a response, then gives up. Exit 0 is recorded for a 2xx
response, exit 1 for any other HTTP status, and exit 127 for network errors.

The default URL in the configure sheet (`http://127.0.0.1:9876/event/ping`)
works out of the box with the
[await-mcp](https://github.com/brycehans/await-mcp) plugin, which lets a Claude
Code session block until a named event arrives:

```
/await ping
```

Then arm the watcher — Claude resumes the moment the watcher fires.

## URL Automation

PixelWatch registers the `pixelwatch://` URL scheme when launched from
`PixelWatch.app`.

Find watcher IDs in the persisted watcher file:

```sh
cat ~/Library/Application\ Support/PixelWatch/watchers.json
```

Then call:

```sh
open "pixelwatch://arm?id=<UUID>"
open "pixelwatch://pause?id=<UUID>"
open "pixelwatch://delete?id=<UUID>"
open "pixelwatch://show"
open "pixelwatch://hide"
```

Actions:

- `arm`: resolve the target window, capture a fresh baseline, and start watching.
- `pause`: persist `armed=false` and move the watcher to `idle`.
- `delete`: remove the watcher.
- `show` / `hide`: open or close the menu-bar popover.

These URLs work from tools such as Raycast, BetterTouchTool, Shortcuts, shell
scripts, and any macOS app that can open URLs.

## Debug Socket

PixelWatch exposes a JSONL debug socket at:

```text
~/Library/Application Support/PixelWatch/bus.sock
```

Read internal events:

```sh
nc -U ~/Library/Application\ Support/PixelWatch/bus.sock
```

Start the new-watcher flow externally:

```sh
printf '{"cmd":"newWatcher"}\n' | nc -U ~/Library/Application\ Support/PixelWatch/bus.sock
```

Quit PixelWatch:

```sh
printf '{"cmd":"quit"}\n' | nc -U ~/Library/Application\ Support/PixelWatch/bus.sock
```

Simulate dropping the create tile at AppKit screen coordinates:

```sh
printf '{"cmd":"dropAt","x":800,"y":600}\n' | nc -U ~/Library/Application\ Support/PixelWatch/bus.sock
```

The debug socket is a development/debugging surface and currently starts
unconditionally.

## Persistence

Watcher configuration is stored at:

```text
~/Library/Application Support/PixelWatch/watchers.json
```

Only watcher configuration is persisted: target binding, rectangle,
sensitivity, cadence, command mode, and whether the watcher should be armed on
launch. Runtime data such as baselines, frames, scores, and state-machine
details are rebuilt each launch.

## Benchmark CLI

The package also includes `pixelwatch-bench`, a performance validation
executable used to exercise the diff/capture path.

```sh
swift build -c release
.build/release/pixelwatch-bench --out docs/bench-results/$(date +%Y-%m-%d).json
```

The benchmark is mostly frozen; production code uses the vectorised diff
implementation in `PixelWatchCore`.

## Development

Run all tests:

```sh
swift test
```

Run a target or a single test:

```sh
swift test --filter PixelWatchCoreTests
swift test --filter PixelWatchCoreTests.WatcherStateMachineTests
swift test --filter PixelWatchCoreTests.DiffTests/testIdenticalImagesScoreZero
```

Package layout:

```text
Sources/PixelWatchCore/        Headless event pipeline, capture, diff, hooks, persistence.
Sources/PixelWatchAppSupport/  AppKit/SwiftUI UI support.
Sources/pixelwatch/            Menu-bar app entry point.
Sources/pixelwatch-bench/      Benchmark executable.
Tests/                         Core and app-support tests.
docs/plans/                    Design and implementation notes.
docs/adr/                      Accepted architectural decisions.
```

`CONTEXT.md` is the glossary and source of truth for domain terms such as
Watcher, Arm, Pause, Fire, Baseline, Frame, Score, and WindowBinding.

## Troubleshooting

### PixelWatch Cannot Capture The Window

Check Screen Recording permission for the launcher you used. If you switched
from `swift run pixelwatch` to `PixelWatch.app`, grant permission to the bundle
too and relaunch it.

### URL Commands Do Nothing

Run:

```sh
make bundle
open PixelWatch.app
```

Then retry the `open "pixelwatch://..."` command. URL routing depends on the
registered app bundle.

### Notification Mode Does Nothing

Install and verify `terminal-notifier`, or use shell-command mode with your own
notification command.

### Hook Output Is Missing

PixelWatch does not show hook output in the UI. Use OSLog:

```sh
log show --predicate 'subsystem == "com.bryce.pixelwatch"' --last 1h
```
