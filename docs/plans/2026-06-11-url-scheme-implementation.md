# URL Scheme Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Register a `pixelwatch://` URL scheme so external tools (BetterTouchTool, Raycast, shell scripts) can arm, pause, and delete watchers by UUID.

**Architecture:** `NSApplicationDelegate.application(_:open:)` receives incoming URLs. A pure `URLCommand` parser (tested) decodes the URL into a typed command. The delegate dispatches to existing `handleArmWatcher`/`handleDeleteWatcher` and a new `handlePauseWatcher`. Pause publishes `.paused` to the bus (the event monitor updates overlays automatically) and writes `armed: false` to `watchers.json`. An `Info.plist` + `Makefile` bundle target enables Launch Services registration.

**Tech Stack:** Swift 6 / AppKit, SwiftPM 6.0, XCTest

---

### Task 1: URL parser — failing tests

**Files:**
- Create: `Sources/PixelWatchAppSupport/URLCommandParser.swift`
- Create: `Tests/PixelWatchAppSupportTests/URLCommandParserTests.swift`

**Step 1: Write the failing tests**

`Tests/PixelWatchAppSupportTests/URLCommandParserTests.swift`:
```swift
import Foundation
import XCTest
@testable import PixelWatchAppSupport

final class URLCommandParserTests: XCTestCase {

  func testParsesArmURL() {
    let id = UUID()
    let url = URL(string: "pixelwatch://arm?id=\(id.uuidString)")!
    XCTAssertEqual(URLCommandParser.parse(url), .arm(id: id))
  }

  func testParsesPauseURL() {
    let id = UUID()
    let url = URL(string: "pixelwatch://pause?id=\(id.uuidString)")!
    XCTAssertEqual(URLCommandParser.parse(url), .pause(id: id))
  }

  func testParsesDeleteURL() {
    let id = UUID()
    let url = URL(string: "pixelwatch://delete?id=\(id.uuidString)")!
    XCTAssertEqual(URLCommandParser.parse(url), .delete(id: id))
  }

  func testReturnsNilForUnknownAction() {
    let id = UUID()
    let url = URL(string: "pixelwatch://frobnicate?id=\(id.uuidString)")!
    XCTAssertNil(URLCommandParser.parse(url))
  }

  func testReturnsNilForMissingID() {
    let url = URL(string: "pixelwatch://arm")!
    XCTAssertNil(URLCommandParser.parse(url))
  }

  func testReturnsNilForMalformedID() {
    let url = URL(string: "pixelwatch://arm?id=not-a-uuid")!
    XCTAssertNil(URLCommandParser.parse(url))
  }
}
```

**Step 2: Run tests to confirm they fail**

```
swift test --filter PixelWatchAppSupportTests.URLCommandParserTests
```

Expected: build error — `URLCommandParser` not found.

---

### Task 2: URL parser — implementation

**Files:**
- Implement: `Sources/PixelWatchAppSupport/URLCommandParser.swift`

**Step 1: Write the implementation**

```swift
import Foundation
import PixelWatchCore

public enum URLCommand: Equatable, Sendable {
  case arm(id: WatcherID)
  case pause(id: WatcherID)
  case delete(id: WatcherID)
}

public enum URLCommandParser {
  public static func parse(_ url: URL) -> URLCommand? {
    guard
      let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      let action = components.host,
      let idString = components.queryItems?.first(where: { $0.name == "id" })?.value,
      let id = UUID(uuidString: idString)
    else { return nil }

    switch action {
    case "arm":    return .arm(id: id)
    case "pause":  return .pause(id: id)
    case "delete": return .delete(id: id)
    default:       return nil
    }
  }
}
```

**Step 2: Run tests to confirm they pass**

```
swift test --filter PixelWatchAppSupportTests.URLCommandParserTests
```

Expected: 6 tests pass.

**Step 3: Commit**

Write to `tmp/commit-msg.txt`:
```
feat: add URLCommandParser for pixelwatch:// URL scheme

Parses arm/pause/delete URLs into typed URLCommand values.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
Claude-Session: f87b055a-75b7-444f-b577-97aa48ef360d
```

```
git add Sources/PixelWatchAppSupport/URLCommandParser.swift Tests/PixelWatchAppSupportTests/URLCommandParserTests.swift
git commit -F tmp/commit-msg.txt
rm tmp/commit-msg.txt
```

---

### Task 3: handlePauseWatcher + application(_:open:) in the delegate

**Files:**
- Modify: `Sources/pixelwatch/PixelWatchMain.swift`

The delegate already holds `watchers: [Watcher]`, `persistence`, and `bus`. Pause needs to:
1. Find the watcher in `watchers` by ID and flip `armed = false`
2. Persist the updated array
3. Publish `.paused(watcherID:, reason: .userPaused)` to `bus` (WatcherStore reacts automatically; event monitor updates overlays)

The URL handler is a one-liner that calls `URLCommandParser.parse(_:)` and dispatches.

**Step 1: Add `handlePauseWatcher` to `PixelWatchAppDelegate`**

Add this private method to `PixelWatchAppDelegate`, alongside the existing `handleArmWatcher` and `handleDeleteWatcher`:

```swift
private func handlePauseWatcher(id: WatcherID) {
  guard let idx = watchers.firstIndex(where: { $0.id == id }) else {
    NSLog("handlePauseWatcher: unknown watcher %@", id.uuidString)
    return
  }
  watchers[idx].armed = false
  do {
    try persistence.save(watchers)
  } catch {
    NSLog("Failed to persist pause for %@: %@", id.uuidString, error.localizedDescription)
  }
  Task {
    await bus.publish(.paused(watcherID: id, reason: .userPaused))
  }
}
```

**Step 2: Add `application(_:open:)` to `PixelWatchAppDelegate`**

Add alongside `applicationDidFinishLaunching`:

```swift
func application(_ application: NSApplication, open urls: [URL]) {
  for url in urls {
    guard let command = URLCommandParser.parse(url) else {
      NSLog("[URL] unrecognised URL: %@", url.absoluteString)
      continue
    }
    switch command {
    case .arm(let id):    handleArmWatcher(id: id)
    case .pause(let id):  handlePauseWatcher(id: id)
    case .delete(let id): handleDeleteWatcher(id: id)
    }
  }
}
```

**Step 3: Build to confirm no errors**

```
swift build 2>&1 | grep -E "error:|warning:" | head -20
```

Expected: no errors.

**Step 4: Commit**

Write to `tmp/commit-msg.txt`:
```
feat: wire pixelwatch:// URL handler in app delegate

Handles arm/pause/delete URLs. Pause publishes .paused to the bus
and persists armed=false to watchers.json so it survives restart.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
Claude-Session: f87b055a-75b7-444f-b577-97aa48ef360d
```

```
git add Sources/pixelwatch/PixelWatchMain.swift
git commit -F tmp/commit-msg.txt
rm tmp/commit-msg.txt
```

---

### Task 4: Info.plist + Makefile bundle target

The URL scheme only activates when the app runs from a proper `.app` bundle registered with Launch Services. A bare `swift run pixelwatch` binary won't receive URL events. This task creates the Info.plist and a `make bundle` target.

**Files:**
- Create: `Sources/pixelwatch/Info.plist`
- Create: `Makefile`

**Step 1: Create `Sources/pixelwatch/Info.plist`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key>
  <string>com.bryce.pixelwatch</string>
  <key>CFBundleName</key>
  <string>PixelWatch</string>
  <key>CFBundleExecutable</key>
  <string>pixelwatch</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key>
      <string>com.bryce.pixelwatch</string>
      <key>CFBundleURLSchemes</key>
      <array>
        <string>pixelwatch</string>
      </array>
    </dict>
  </array>
</dict>
</plist>
```

**Step 2: Create `Makefile`**

```makefile
BINARY := .build/release/pixelwatch
BUNDLE := PixelWatch.app

.PHONY: build bundle run clean

build:
	swift build -c release

bundle: build
	rm -rf $(BUNDLE)
	mkdir -p $(BUNDLE)/Contents/MacOS
	cp $(BINARY) $(BUNDLE)/Contents/MacOS/pixelwatch
	cp Sources/pixelwatch/Info.plist $(BUNDLE)/Contents/Info.plist
	touch $(BUNDLE)
	/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u $(BUNDLE) 2>/dev/null; true
	/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister $(BUNDLE)
	@echo "Bundle created and registered. Run with: open $(BUNDLE)"

run: bundle
	open $(BUNDLE)

clean:
	rm -rf .build $(BUNDLE)
```

**Step 3: Build the bundle and verify**

```
make bundle
```

Expected: creates `PixelWatch.app/` and prints "Bundle created and registered."

**Step 4: Test URL scheme end-to-end**

With the app running (`make run` or `open PixelWatch.app`):

```bash
# List your watcher IDs from the persisted state:
cat ~/Library/Application\ Support/PixelWatch/watchers.json | fx '.[] | .id'

# Replace <UUID> with a real ID from above:
open "pixelwatch://arm?id=<UUID>"
open "pixelwatch://pause?id=<UUID>"
open "pixelwatch://delete?id=<UUID>"
```

Verify in the app's popover that state changes are reflected.

**Step 5: Commit**

Write to `tmp/commit-msg.txt`:
```
feat: add Info.plist URL scheme registration and Makefile bundle target

Registers the pixelwatch:// URL scheme via CFBundleURLTypes. The Makefile
bundle target wraps the SwiftPM binary into a .app bundle and registers it
with Launch Services so macOS routes pixelwatch:// URLs to the running app.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
Claude-Session: f87b055a-75b7-444f-b577-97aa48ef360d
```

```
git add Sources/pixelwatch/Info.plist Makefile
git commit -F tmp/commit-msg.txt
rm tmp/commit-msg.txt
```

---

## Quick-reference URLs (after `make run`)

```bash
# Arm a watcher
open "pixelwatch://arm?id=<UUID>"

# Pause a watcher (persists across restart)
open "pixelwatch://pause?id=<UUID>"

# Delete a watcher
open "pixelwatch://delete?id=<UUID>"

# Get watcher IDs
cat ~/Library/Application\ Support/PixelWatch/watchers.json | fx '.[] | {id: .id, name: .target.bundleID}'
```

In BetterTouchTool: use an "Open URL" action with `pixelwatch://arm?id=<UUID>`.
