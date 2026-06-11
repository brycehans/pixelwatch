# Popover URL Commands Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `pixelwatch://show` and `pixelwatch://hide`, publish those requests on the event bus, and have the app delegate react by showing or hiding the popover.

**Architecture:** Extend the URL parser with non-watcher actions, add dedicated popover-request cases to `PixelWatchEvent`, and handle those events in the app delegate's existing bus subscription path. Keep watcher-domain URL behavior unchanged.

**Tech Stack:** Swift 6, AppKit, Foundation, XCTest

---

### Task 1: Extend parser tests first

**Files:**
- Modify: `Tests/PixelWatchAppSupportTests/URLCommandParserTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
func testParsesShowURL() {
  let url = URL(string: "pixelwatch://show")!
  XCTAssertEqual(URLCommandParser.parse(url), .showPopover)
}

func testParsesHideURL() {
  let url = URL(string: "pixelwatch://hide")!
  XCTAssertEqual(URLCommandParser.parse(url), .hidePopover)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter PixelWatchAppSupportTests.URLCommandParserTests`
Expected: FAIL because `.showPopover` / `.hidePopover` do not exist yet.

- [ ] **Step 3: Write minimal implementation**

Extend `URLCommand` and `URLCommandParser.parse(_:)` so `show` and `hide` parse without an `id`, while watcher actions still require one.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter PixelWatchAppSupportTests.URLCommandParserTests`
Expected: PASS

### Task 2: Add event codable coverage

**Files:**
- Modify: `Tests/PixelWatchCoreTests`
- Modify: `Sources/PixelWatchCore/Models.swift`
- Modify: `Sources/PixelWatchCore/EventCodable.swift`

- [ ] **Step 1: Write the failing test**

Add a new test file with round-trip assertions for:

```swift
try roundTrip(.popoverShowRequested)
try roundTrip(.popoverHideRequested)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter PixelWatchCoreTests`
Expected: FAIL because the new event cases are not defined/codable yet.

- [ ] **Step 3: Write minimal implementation**

Add the two new `PixelWatchEvent` cases and teach `EventCodable` to encode/decode them.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter PixelWatchCoreTests`
Expected: PASS

### Task 3: Wire app delegate reaction

**Files:**
- Modify: `Sources/pixelwatch/PixelWatchMain.swift`

- [ ] **Step 1: Add failing behavior test if a practical seam exists**

If no existing app-delegate test seam exists, keep this task implementation-led and verify via compilation plus targeted tests from Tasks 1-2.

- [ ] **Step 2: Implement explicit popover helpers**

Add `showPopover()` and `hidePopover()` methods. Make `togglePopover(_:)` delegate to them.

- [ ] **Step 3: Publish and consume popover request events**

Translate `show` / `hide` URL commands into bus publications and react to `popoverShowRequested` / `popoverHideRequested` in the event-consumption loop.

- [ ] **Step 4: Run targeted verification**

Run: `swift test --filter PixelWatchAppSupportTests.URLCommandParserTests`

Run: `swift test --filter PixelWatchCoreTests`

Expected: PASS
