# Backend Core Slice Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Start the production PixelWatch app with test-covered core contracts for event flow, diffing, and watcher state transitions.

**Architecture:** Add a `PixelWatchCore` SwiftPM library beside the existing bench executable. The first slice contains no UI and no ScreenCaptureKit dependency; it establishes pure or actor-isolated primitives that later capture, hook, persistence, and UI layers can depend on.

**Tech Stack:** Swift 6, SwiftPM, XCTest, CoreGraphics, Accelerate.

---

### Task 1: Package And Tests

**Files:**
- Modify: `Package.swift`
- Create: `Tests/PixelWatchCoreTests/EventBusTests.swift`
- Create: `Tests/PixelWatchCoreTests/DiffTests.swift`
- Create: `Tests/PixelWatchCoreTests/WatcherStateMachineTests.swift`

- [ ] Add a `PixelWatchCore` library target and `PixelWatchCoreTests` test target.
- [ ] Write tests first for multi-subscriber event fan-out, diff scores, threshold mapping, and fire-to-triggered state transitions.
- [ ] Run `swift test --filter PixelWatchCoreTests` and confirm it fails because production symbols do not exist.

### Task 2: Core Types

**Files:**
- Create: `Sources/PixelWatchCore/Models.swift`

- [ ] Add `WatcherID`, `Watcher`, `WindowBinding`, `TitleMatch`, `WatcherState`, `FireReason`, `VanishReason`, `PauseReason`, and `PixelWatchEvent`.
- [ ] Keep the model aligned with `CONTEXT.md`: no cooldown/post-fire mode, no `enabled`, persisted desired runtime is `armed: Bool`, and `WindowBinding` uses `windowIDHint` plus `lastKnownBounds`.
- [ ] Run the tests and continue to the next missing symbol.

### Task 3: Event Bus

**Files:**
- Create: `Sources/PixelWatchCore/EventBus.swift`

- [ ] Implement an `EventBus` actor with `publish(_:)` and `subscribe() -> AsyncStream<PixelWatchEvent>`.
- [ ] Ensure every active subscriber receives every published event.
- [ ] Remove a subscriber continuation when its stream terminates.
- [ ] Run the event bus tests and confirm they pass.

### Task 4: Diff

**Files:**
- Create: `Sources/PixelWatchCore/Diff.swift`

- [ ] Port the bench `Diff` implementation, preserving the vectorised `vvpowsf` gamma conversion.
- [ ] Expose `PixelBuffer` and `Diff.makeBuffer(from:maxLongEdge:)` / `Diff.score(baseline:current:epsilon:)`.
- [ ] Run the diff tests and confirm they pass.

### Task 5: Watcher State Machine

**Files:**
- Create: `Sources/PixelWatchCore/WatcherStateMachine.swift`

- [ ] Implement the four states from `CONTEXT.md`: `idle`, `armed`, `triggered`, `errored`.
- [ ] Implement transitions for `armed`, `thresholdExceeded`, `windowVanished`, `paused`, and `errored`.
- [ ] Add `DecideStage.threshold(forSensitivity:)` with `0.001 * 200^(1 - slider)`.
- [ ] Run the state machine tests and confirm they pass.

### Task 6: Verification

**Files:**
- Review: `Package.swift`
- Review: `Sources/PixelWatchCore/*`
- Review: `Tests/PixelWatchCoreTests/*`

- [ ] Run `swift test`.
- [ ] Run `swift build`.
- [ ] Report exact verification results and any remaining gaps.
