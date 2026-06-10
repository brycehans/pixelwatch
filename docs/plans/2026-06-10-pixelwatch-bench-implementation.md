# PixelWatch Benchmark CLI Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a ~200-line SwiftPM executable that validates the parent design's capture+diff cost targets (idle <1% CPU/watcher, 20-watcher RSS <50 MB, p99 latency <50 ms) before any UI work begins.

**Architecture:** Single-process SwiftPM executable. Spawns its own AppKit test window (static half + animated half), runs N watchers concurrently with `TaskGroup` at 1 Hz, each watcher captures via `SCScreenshotManager` and diffs against a baseline using vImage downsample + linear-RGB ΔE. Samples per-cycle latency, process CPU%, and process RSS. Writes results as JSON.

**Tech Stack:** Swift 6 toolchain (tools-version 6.0 in `Package.swift`; `.v15` platform requires it), macOS 15 SDK, SwiftPM (no external deps), AppKit, ScreenCaptureKit, Accelerate (vImage/vDSP), Darwin (`proc_pid_rusage`, `task_info`).

**Reference docs:**
- Parent design: `docs/plans/2026-06-10-pixelwatch-design.md`
- Bench design: `docs/plans/2026-06-10-pixelwatch-bench-design.md`

**Testing strategy:** None. This is a throwaway measurement tool; its JSON output IS the validation. Build, run, eyeball. No test target, no TDD, no smoke tests. (Per a 2026-06-10 decision — the original plan had TDD on `Diff` + `Metrics` + an E2E smoke test; that scaffolding was deleted before Task 2.)

**Permission note:** Capturing requires Screen Recording (TCC). On first run, macOS will prompt; the build must be run from a terminal that has the entitlement granted (`System Settings → Privacy → Screen Recording`).

---

## Task 1: SwiftPM package skeleton

> **Historical note:** The original Task 1 created a `Tests/pixelwatch-benchTests/` target with a trivial smoke test. After Task 1 shipped, the test target was deleted (see "Testing strategy" above). Future re-readers: ignore the test-related artefacts mentioned below; they were a transient decision.

**Files:**
- Create: `Package.swift`
- Create: `Sources/pixelwatch-bench/main.swift`
- Create: `.gitignore`

**Step 1: Write `Package.swift`**

```swift
// swift-tools-version:6.0
import PackageDescription

let package = Package(
  name: "pixelwatch-bench",
  platforms: [.macOS(.v15)],
  targets: [
    .executableTarget(
      name: "pixelwatch-bench",
      path: "Sources/pixelwatch-bench"
    ),
  ]
)
```

**Step 2: Write a stub `main.swift`**

```swift
import Foundation

@main
struct Bench {
  static func main() {
    print("pixelwatch-bench ready")
  }
}
```

**Step 4: Write `.gitignore`**

```
.build/
.swiftpm/
*.xcodeproj/
bench-*.json
```

**Step 5: Verify**

Run: `swift build`
Expected: `Build complete!`

Run: `swift run pixelwatch-bench`
Expected: `pixelwatch-bench ready`

**Step 6: Commit**

```bash
git add Package.swift Sources .gitignore
git commit -F tmp/commit-msg.txt  # see CLAUDE.local.md
```

Commit message:

```
Scaffold pixelwatch-bench SwiftPM package

Empty executable + test target, builds and runs.
```

---

## Task 2: Diff algorithm

**Files:**
- Create: `Sources/pixelwatch-bench/Diff.swift`

**API to implement:**

```swift
struct PixelBuffer {
  let width: Int
  let height: Int
  let linearRGB: [Float]   // length = width * height * 3, range [0,1]
}

enum Diff {
  /// Build a downsampled, linear-RGB PixelBuffer from a CGImage.
  /// Downsamples so the long edge is at most `maxLongEdge` (default 256), bilinear.
  static func makeBuffer(from image: CGImage, maxLongEdge: Int = 256) -> PixelBuffer

  /// Per-pixel Euclidean ΔE in linear RGB. Returns fraction of pixels with ΔE > epsilon.
  /// Buffers must have identical dimensions.
  static func score(baseline: PixelBuffer, current: PixelBuffer, epsilon: Float = 0.03) -> Double
}
```

**Step 1: Implement `Diff.swift`**

```swift
import Foundation
import CoreGraphics
import Accelerate

struct PixelBuffer {
  let width: Int
  let height: Int
  let linearRGB: [Float]   // length = width * height * 3
}

enum Diff {

  static func makeBuffer(from image: CGImage, maxLongEdge: Int = 256) -> PixelBuffer {
    // 1. Compute target dims preserving aspect.
    let srcW = image.width, srcH = image.height
    let long = max(srcW, srcH)
    let scale = long > maxLongEdge ? Double(maxLongEdge) / Double(long) : 1.0
    let dstW = max(1, Int((Double(srcW) * scale).rounded()))
    let dstH = max(1, Int((Double(srcH) * scale).rounded()))

    // 2. Draw into an RGBA8 sRGB context at dstW × dstH (bilinear via CG).
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let bytesPerRow = dstW * 4
    var rgba = [UInt8](repeating: 0, count: dstW * dstH * 4)
    let ctx = CGContext(
      data: &rgba, width: dstW, height: dstH,
      bitsPerComponent: 8, bytesPerRow: bytesPerRow,
      space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.interpolationQuality = .medium
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: dstW, height: dstH))

    // 3. Convert sRGB-encoded UInt8 → linear-RGB Float per channel.
    //    Uses fast gamma-2.2 approximation per the design.
    var linear = [Float](repeating: 0, count: dstW * dstH * 3)
    for p in 0..<(dstW * dstH) {
      let r = Float(rgba[p*4 + 0]) / 255
      let g = Float(rgba[p*4 + 1]) / 255
      let b = Float(rgba[p*4 + 2]) / 255
      linear[p*3 + 0] = pow(r, 2.2)
      linear[p*3 + 1] = pow(g, 2.2)
      linear[p*3 + 2] = pow(b, 2.2)
    }
    return PixelBuffer(width: dstW, height: dstH, linearRGB: linear)
  }

  static func score(baseline: PixelBuffer, current: PixelBuffer, epsilon: Float = 0.03) -> Double {
    precondition(baseline.width == current.width && baseline.height == current.height,
                 "score: buffer dimensions must match")
    let pixelCount = baseline.width * baseline.height
    var changed = 0
    let eps2 = epsilon * epsilon
    baseline.linearRGB.withUnsafeBufferPointer { bp in
      current.linearRGB.withUnsafeBufferPointer { cp in
        for p in 0..<pixelCount {
          let dr = cp[p*3 + 0] - bp[p*3 + 0]
          let dg = cp[p*3 + 1] - bp[p*3 + 1]
          let db = cp[p*3 + 2] - bp[p*3 + 2]
          if dr*dr + dg*dg + db*db > eps2 { changed += 1 }
        }
      }
    }
    return Double(changed) / Double(pixelCount)
  }
}
```

**Step 2: Verify it compiles**

Run: `swift build`
Expected: `Build complete!`

**Step 3: Commit**

Commit message:

```
Add Diff: downsample + linear-RGB ΔE score

Per-pixel Euclidean ΔE in linear RGB, score = fraction past epsilon.
Buffers downsampled to <=256 px long edge via CG bilinear before
linearisation.
```

---

## Task 3: Metrics

**Files:**
- Create: `Sources/pixelwatch-bench/Metrics.swift`

**API to implement:**

```swift
enum Metrics {
  /// Cumulative user+system CPU time for the current process, in seconds.
  static func processCPUSeconds() -> Double

  /// Resident set size for the current process, in bytes.
  static func processRSSBytes() -> UInt64
}
```

**Step 1: Implement `Metrics.swift`**

```swift
import Foundation
import Darwin

enum Metrics {

  static func processCPUSeconds() -> Double {
    var info = rusage_info_v6()
    let ok = withUnsafeMutablePointer(to: &info) { ptr -> Int32 in
      ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
        proc_pid_rusage(getpid(), RUSAGE_INFO_V6, rebound)
      }
    }
    guard ok == 0 else { return 0 }
    let userNs = info.ri_user_time
    let sysNs  = info.ri_system_time
    return Double(userNs + sysNs) / 1_000_000_000.0
  }

  static func processRSSBytes() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size)
    let ok = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
      ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
        task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rebound, &count)
      }
    }
    guard ok == KERN_SUCCESS else { return 0 }
    return UInt64(info.resident_size)
  }
}
```

**Step 2: Verify it compiles**

Run: `swift build`
Expected: `Build complete!`

**Step 3: Commit**

Commit message:

```
Add Metrics: process CPU seconds + RSS via Darwin

processCPUSeconds() = user+system rusage from proc_pid_rusage(V6).
processRSSBytes() = resident_size from task_info(MACH_TASK_BASIC_INFO).
```

---

## Task 4: Capture wrapper

**Files:**
- Create: `Sources/pixelwatch-bench/Capture.swift`

No unit test — `SCScreenshotManager` needs TCC. Exercised by the real bench run in Task 8.

**Step 1: Implement `Capture.swift`**

```swift
import Foundation
import ScreenCaptureKit
import CoreGraphics

enum CaptureError: Error {
  case windowNotFound
  case captureFailed(Error)
}

actor Capture {
  /// Look up an SCWindow by `CGWindowID`. Refreshes each call (the bench's
  /// window is stable for a run, but we don't rely on it).
  static func findWindow(cgWindowID: CGWindowID) async throws -> SCWindow {
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    guard let w = content.windows.first(where: { $0.windowID == cgWindowID }) else {
      throw CaptureError.windowNotFound
    }
    return w
  }

  /// Capture the given window at native scale. Returns a CGImage at the
  /// window's full pixel dimensions; callers crop to their rect.
  static func captureWindow(_ window: SCWindow) async throws -> CGImage {
    let filter = SCContentFilter(desktopIndependentWindow: window)
    let cfg = SCStreamConfiguration()
    cfg.width = Int(window.frame.width * 2)   // assume @2x; downsample later anyway
    cfg.height = Int(window.frame.height * 2)
    cfg.pixelFormat = kCVPixelFormatType_32BGRA
    cfg.showsCursor = false
    do {
      return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
    } catch {
      throw CaptureError.captureFailed(error)
    }
  }

  /// Crop a CGImage to a window-relative rect (in points). The image is at
  /// 2x; rect is scaled accordingly.
  static func crop(_ image: CGImage, toPoints rect: CGRect, scale: CGFloat = 2) -> CGImage? {
    let pixelRect = CGRect(
      x: rect.origin.x * scale,
      y: rect.origin.y * scale,
      width: rect.width * scale,
      height: rect.height * scale
    )
    return image.cropping(to: pixelRect)
  }
}
```

**Step 2: Verify it compiles**

Run: `swift build`
Expected: `Build complete!`

**Step 3: Commit**

Commit message:

```
Add Capture: SCScreenshotManager wrapper

findWindow + captureWindow + crop. SCScreenshotManager needs TCC and
isn't unit-testable without it; exercised by the real bench run.
```

---

## Task 5: TestWindow

**Files:**
- Create: `Sources/pixelwatch-bench/TestWindow.swift`

**Step 1: Implement `TestWindow.swift`**

```swift
import AppKit
import QuartzCore

/// 800x400 borderless window: left half static mid-grey, right half hue-cycling at ~5 Hz.
/// Returns its CGWindowID once it's on-screen.
final class TestWindow {

  let window: NSWindow
  private let animatedLayer: CALayer
  private var displayLink: CVDisplayLink?
  private var startTime = CFAbsoluteTimeGetCurrent()

  init() {
    window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 800, height: 400),
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    window.title = "PixelWatch Bench"
    window.level = .floating
    window.isReleasedWhenClosed = false
    window.center()

    let root = CALayer()
    root.frame = CGRect(x: 0, y: 0, width: 800, height: 400)

    let staticHalf = CALayer()
    staticHalf.frame = CGRect(x: 0, y: 0, width: 400, height: 400)
    staticHalf.backgroundColor = CGColor(gray: 0.5, alpha: 1)
    root.addSublayer(staticHalf)

    animatedLayer = CALayer()
    animatedLayer.frame = CGRect(x: 400, y: 0, width: 400, height: 400)
    animatedLayer.backgroundColor = CGColor(red: 1, green: 0, blue: 0, alpha: 1)
    root.addSublayer(animatedLayer)

    let content = NSView(frame: root.frame)
    content.wantsLayer = true
    content.layer = root
    window.contentView = content
  }

  func show() {
    window.makeKeyAndOrderFront(nil)
    startDisplayLink()
  }

  func close() {
    stopDisplayLink()
    window.close()
  }

  /// Block until the window has a CGWindowID we can capture, up to `timeout` seconds.
  func waitForCGWindowID(timeout: TimeInterval = 2) -> CGWindowID? {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if let id = currentCGWindowID() { return id }
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    return nil
  }

  private func currentCGWindowID() -> CGWindowID? {
    let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
    guard let infos = raw as? [[String: Any]] else { return nil }
    let pid = ProcessInfo.processInfo.processIdentifier
    for info in infos {
      if let ownerPID = info[kCGWindowOwnerPID as String] as? Int32, ownerPID == pid,
         let name = info[kCGWindowName as String] as? String, name == "PixelWatch Bench",
         let id = info[kCGWindowNumber as String] as? CGWindowID {
        return id
      }
    }
    return nil
  }

  // MARK: animated half — hue cycle at ~5 Hz

  private func startDisplayLink() {
    var link: CVDisplayLink?
    CVDisplayLinkCreateWithActiveCGDisplays(&link)
    guard let link else { return }
    let pointer = Unmanaged.passUnretained(self).toOpaque()
    CVDisplayLinkSetOutputCallback(link, { _, _, _, _, _, ctx in
      let me = Unmanaged<TestWindow>.fromOpaque(ctx!).takeUnretainedValue()
      DispatchQueue.main.async { me.tick() }
      return kCVReturnSuccess
    }, pointer)
    CVDisplayLinkStart(link)
    displayLink = link
  }

  private func stopDisplayLink() {
    if let link = displayLink { CVDisplayLinkStop(link) }
    displayLink = nil
  }

  private func tick() {
    let t = CFAbsoluteTimeGetCurrent() - startTime
    let hue = CGFloat((t * 5).truncatingRemainder(dividingBy: 1))   // 5 Hz cycle
    let color = NSColor(hue: hue, saturation: 1, brightness: 1, alpha: 1).cgColor
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    animatedLayer.backgroundColor = color
    CATransaction.commit()
  }
}
```

**Step 2: Verify it compiles**

Run: `swift build`
Expected: `Build complete!`

**Step 3: Commit**

Commit message:

```
Add TestWindow: static + animated halves

Borderless 800x400 floating window, left half static mid-grey, right
half hue-cycling at ~5 Hz via CVDisplayLink. Exposes waitForCGWindowID
so the bench can resolve the window before starting captures.
```

---

## Task 6: BenchRun

**Files:**
- Create: `Sources/pixelwatch-bench/BenchRun.swift`

**Step 1: Implement `BenchRun.swift`**

```swift
import Foundation
import ScreenCaptureKit
import CoreGraphics

struct WatcherSample: Codable {
  let id: Int
  let side: String           // "static" | "animated"
  var latencyMs: [Double]
}

struct RunResult: Codable {
  let n: Int
  let warmupSec: Double
  let durationSec: Double
  let watchers: [WatcherSample]
  let cpuPctSamples: [Double]
  let rssBytesSamples: [UInt64]
  let errors: [BenchError]
}

struct BenchError: Codable {
  let n: Int
  let watcherId: Int
  let message: String
}

actor BenchRun {

  let cgWindowID: CGWindowID
  let n: Int
  let warmupSec: Double
  let durationSec: Double

  private var watcherBaselines: [PixelBuffer] = []
  private var samples: [WatcherSample] = []
  private var cpuPctSamples: [Double] = []
  private var rssBytesSamples: [UInt64] = []
  private var errors: [BenchError] = []

  // Half static, half animated.
  private let staticRect = CGRect(x: 50, y: 50, width: 300, height: 300)
  private let animatedRect = CGRect(x: 450, y: 50, width: 300, height: 300)

  init(cgWindowID: CGWindowID, n: Int, warmupSec: Double, durationSec: Double) {
    self.cgWindowID = cgWindowID
    self.n = n
    self.warmupSec = warmupSec
    self.durationSec = durationSec
    self.samples = (0..<n).map { id in
      WatcherSample(id: id, side: id < n/2 + n%2 ? "static" : "animated", latencyMs: [])
    }
  }

  func run() async -> RunResult {
    let window = try? await Capture.findWindow(cgWindowID: cgWindowID)
    guard let window else {
      return RunResult(n: n, warmupSec: warmupSec, durationSec: durationSec,
                       watchers: samples, cpuPctSamples: [], rssBytesSamples: [],
                       errors: [BenchError(n: n, watcherId: -1, message: "window-not-found")])
    }

    // 1. Capture an initial frame to build per-watcher baselines.
    if let frame = try? await Capture.captureWindow(window) {
      for i in 0..<n {
        let rect = rectFor(watcher: i)
        if let cropped = Capture.crop(frame, toPoints: rect) {
          watcherBaselines.append(Diff.makeBuffer(from: cropped))
        } else {
          watcherBaselines.append(PixelBuffer(width: 1, height: 1, linearRGB: [0,0,0]))
          errors.append(BenchError(n: n, watcherId: i, message: "baseline-crop-failed"))
        }
      }
    } else {
      return RunResult(n: n, warmupSec: warmupSec, durationSec: durationSec,
                       watchers: samples, cpuPctSamples: [], rssBytesSamples: [],
                       errors: [BenchError(n: n, watcherId: -1, message: "baseline-capture-failed")])
    }

    // 2. Warmup ticks (results discarded).
    let warmupTicks = Int(warmupSec.rounded())
    for _ in 0..<warmupTicks {
      _ = await tickOnce(window: window, record: false)
      try? await Task.sleep(nanoseconds: 1_000_000_000)
    }

    // 3. Measurement ticks.
    let measureTicks = Int(durationSec.rounded())
    var prevCPU = Metrics.processCPUSeconds()
    for _ in 0..<measureTicks {
      let tickStart = Date()
      await tickOnce(window: window, record: true)
      let elapsed = Date().timeIntervalSince(tickStart)
      let remaining = max(0, 1.0 - elapsed)
      try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))

      // Per-second process metrics.
      let cpu = Metrics.processCPUSeconds()
      cpuPctSamples.append((cpu - prevCPU) * 100)   // 1s window
      prevCPU = cpu
      rssBytesSamples.append(Metrics.processRSSBytes())
    }

    return RunResult(
      n: n, warmupSec: warmupSec, durationSec: durationSec,
      watchers: samples,
      cpuPctSamples: cpuPctSamples,
      rssBytesSamples: rssBytesSamples,
      errors: errors
    )
  }

  @discardableResult
  private func tickOnce(window: SCWindow, record: Bool) async -> Bool {
    let frame: CGImage
    do { frame = try await Capture.captureWindow(window) }
    catch {
      if record { errors.append(BenchError(n: n, watcherId: -1, message: "capture: \(error)")) }
      return false
    }

    await withTaskGroup(of: (Int, Double?).self) { group in
      for i in 0..<n {
        group.addTask { [self] in
          let t0 = DispatchTime.now().uptimeNanoseconds
          let rect = await self.rectFor(watcher: i)
          guard let cropped = Capture.crop(frame, toPoints: rect) else { return (i, nil) }
          let current = Diff.makeBuffer(from: cropped)
          _ = Diff.score(baseline: await self.baseline(for: i), current: current)
          let t1 = DispatchTime.now().uptimeNanoseconds
          return (i, Double(t1 - t0) / 1_000_000.0)
        }
      }
      for await (i, latencyMs) in group {
        if record, let ms = latencyMs { samples[i].latencyMs.append(ms) }
        if latencyMs == nil { errors.append(BenchError(n: n, watcherId: i, message: "crop-failed")) }
      }
    }
    return true
  }

  private func baseline(for i: Int) -> PixelBuffer { watcherBaselines[i] }

  private func rectFor(watcher i: Int) -> CGRect {
    // First ceil(n/2) on static, rest on animated.
    let staticCount = (n + 1) / 2
    return i < staticCount ? staticRect : animatedRect
  }
}
```

**Step 2: Verify it compiles**

Run: `swift build`
Expected: `Build complete!`

**Step 3: Commit**

Commit message:

```
Add BenchRun: N-watcher orchestrator

Builds per-watcher baselines, runs warmup + measurement ticks at 1 Hz.
Each tick: one capture, then a TaskGroup that crops + diffs per
watcher concurrently. Records per-cycle latency, plus 1 Hz CPU% and
RSS samples derived from Metrics.
```

---

## Task 7: main.swift — wiring, CLI, JSON output

**Files:**
- Modify: `Sources/pixelwatch-bench/main.swift` (replace stub)

**Step 1: Implement `main.swift`**

```swift
import Foundation
import AppKit

@main
struct Bench {

  struct Options {
    var ns: [Int] = [1, 5, 20, 50]
    var durationSec: Double = 60
    var warmupSec: Double = 5
    var outPath: String = "bench-\(Int(Date().timeIntervalSince1970)).json"
  }

  static func main() async {
    let opts = parseArgs(CommandLine.arguments.dropFirst())

    // AppKit setup — we need an NSApplication for the test window.
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)

    let testWindow = await MainActor.run { TestWindow() }
    await MainActor.run { testWindow.show() }

    // Wait for the window to register.
    let cgID = await MainActor.run { testWindow.waitForCGWindowID() }
    guard let cgWindowID = cgID else {
      FileHandle.standardError.write(Data("error: test window never gained a CGWindowID\n".utf8))
      exit(1)
    }

    var runs: [RunResult] = []
    for n in opts.ns {
      FileHandle.standardError.write(Data("running n=\(n)…\n".utf8))
      let bench = BenchRun(
        cgWindowID: cgWindowID,
        n: n,
        warmupSec: opts.warmupSec,
        durationSec: opts.durationSec
      )
      runs.append(await bench.run())
    }

    await MainActor.run { testWindow.close() }

    let report = Report(
      startedAt: ISO8601DateFormatter().string(from: Date()),
      host: HostInfo.collect(),
      runs: runs
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let json = try! encoder.encode(report)
    try! json.write(to: URL(fileURLWithPath: opts.outPath))
    FileHandle.standardError.write(Data("wrote \(opts.outPath)\n".utf8))
    exit(0)
  }

  static func parseArgs(_ args: ArraySlice<String>) -> Options {
    var opts = Options()
    var it = args.makeIterator()
    while let arg = it.next() {
      switch arg {
      case "--ns":
        if let v = it.next() { opts.ns = v.split(separator: ",").compactMap { Int($0) } }
      case "--duration":
        if let v = it.next(), let d = Double(v) { opts.durationSec = d }
      case "--warmup":
        if let v = it.next(), let d = Double(v) { opts.warmupSec = d }
      case "--out":
        if let v = it.next() { opts.outPath = v }
      case "-h", "--help":
        print("usage: pixelwatch-bench [--ns 1,5,20,50] [--duration 60] [--warmup 5] [--out path.json]")
        exit(0)
      default:
        FileHandle.standardError.write(Data("unknown flag: \(arg)\n".utf8))
        exit(2)
      }
    }
    return opts
  }
}

struct Report: Codable {
  let startedAt: String
  let host: HostInfo
  let runs: [RunResult]
}

struct HostInfo: Codable {
  let os: String
  let cpu: String
  let cores: Int

  static func collect() -> HostInfo {
    let pi = ProcessInfo.processInfo
    return HostInfo(
      os: pi.operatingSystemVersionString,
      cpu: sysctlString("machdep.cpu.brand_string") ?? "unknown",
      cores: pi.activeProcessorCount
    )
  }

  private static func sysctlString(_ name: String) -> String? {
    var size = 0
    sysctlbyname(name, nil, &size, nil, 0)
    guard size > 0 else { return nil }
    var buf = [CChar](repeating: 0, count: size)
    sysctlbyname(name, &buf, &size, nil, 0)
    return String(cString: buf)
  }
}
```

**Step 2: Verify it builds**

Run: `swift build`
Expected: `Build complete!`

**Step 3: Commit**

Commit message:

```
Add main: arg parsing, JSON output, host metadata

Wires TestWindow → BenchRun loop. Spawns NSApplication so AppKit
works; iterates --ns; writes pretty JSON to bench-<unix>.json or
--out path. HostInfo captures os + cpu brand + core count via
sysctlbyname for run reproducibility.
```

---

## Task 8: Run the real benchmark and capture results

This is the actual measurement that motivated the whole CLI.

**Step 1: Build release**

Run: `swift build -c release`
Expected: `Build complete!`

**Step 2: Run the benchmark**

Run: `.build/release/pixelwatch-bench --out docs/bench-results-$(date +%Y%m%d-%H%M%S).json`
Expected: ~5 minutes wall time (4 × 65s + setup). Writes JSON.

**Step 3: Summarise with `fx`**

Run something like:

```sh
fx docs/bench-results-*.json '
  .runs.map(r => ({
    n: r.n,
    cpuMeanPct: r.cpuPctSamples.reduce((a,b)=>a+b,0) / r.cpuPctSamples.length,
    cpuPerWatcherPct: (r.cpuPctSamples.reduce((a,b)=>a+b,0) / r.cpuPctSamples.length) / r.n,
    rssMaxMB: Math.max(...r.rssBytesSamples) / 1048576,
    latencyP99Ms: ((arr) => arr.sort((a,b)=>a-b)[Math.floor(arr.length*0.99)])(r.watchers.flatMap(w => w.latencyMs))
  }))
'
```

**Step 4: Compare to design targets**

| Target | Pass criterion |
|---|---|
| Idle CPU < 1 % per watcher | `cpuPerWatcherPct` at N=20 < 1 (note: includes animated half — interpret with care) |
| 20 watchers RSS < 50 MB | `rssMaxMB` at N=20 < 50 |
| 99p latency < 50 ms | `latencyP99Ms` at every N < 50 |

**Step 5: Decision point**

- **All green:** add a short results section to `docs/plans/2026-06-10-pixelwatch-bench-design.md` ("Results — 2026-06-10") with the numbers, commit. Then start the production app.
- **Any miss:** open a follow-up note documenting which target missed by how much, and revise the parent design (smaller downsample, batched capture, lower default cadence, etc.) before any UI work. **Do not just lower the target.**

**Step 6: Commit results**

Commit message:

```
Record bench results from <date>

n=1/5/20/50 measurements vs. design targets. <pass/miss summary>.
```

---

## Notes for the executor

- Commit messages go through `tmp/commit-msg.txt` per `~/Dev/CLAUDE.local.md` — heredocs in `-m` are blocked by toolgate. Include `Co-Authored-By` and `Claude-Session` trailers in every commit.
- Don't chain `git` commands or `cd …` chains in Bash — toolgate denies them.
- If a Swift API changed in macOS 15 (e.g. `SCScreenshotManager.captureImage` signature), prefer fetching current docs over guessing — there's a `context7` MCP for current library docs.
- The Diff algorithm here will be lifted into the production app's `DiffStage`. Keep it pure and well-tested for that reason.
