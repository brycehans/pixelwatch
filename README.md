# PixelWatch

PixelWatch is a macOS menu-bar app that watches a rectangle inside a window and runs a shell command when the pixels change.

## Build And Run

```sh
swift build
swift run pixelwatch
```

For `pixelwatch://` URL automation, run PixelWatch from an app bundle so macOS Launch Services can route URLs to it:

```sh
make bundle
open PixelWatch.app
```

The app needs Screen Recording permission for the terminal or app bundle that launches it.

## URL Automation

PixelWatch registers the `pixelwatch://` URL scheme when launched from `PixelWatch.app`. Use a persisted watcher UUID from `~/Library/Application Support/PixelWatch/watchers.json`.

```sh
open "pixelwatch://arm?id=<UUID>"
open "pixelwatch://pause?id=<UUID>"
open "pixelwatch://delete?id=<UUID>"
```

`arm` captures a fresh baseline, `pause` persists `armed=false`, and `delete` removes the watcher. These URLs can be used from BetterTouchTool, Raycast, shell scripts, or any macOS tool that can open URLs.

To list watcher IDs:

```sh
cat ~/Library/Application\ Support/PixelWatch/watchers.json
```
