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

/// Per-watcher tick result. Sendable so it can cross the TaskGroup boundary.
private struct TickResult: Sendable {
  let id: Int
  let latencyMs: Double?
}

/// Outcome of one tick: per-watcher results, plus an optional capture-level error.
private struct TickOutcome: Sendable {
  let results: [TickResult]
  let captureError: String?
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

  // Half static, half animated. Coordinates are window-local points; the
  // bench's TestWindow is 800x400 with left half static / right half animated.
  private let staticRect = CGRect(x: 50, y: 50, width: 300, height: 300)
  private let animatedRect = CGRect(x: 450, y: 50, width: 300, height: 300)

  init(cgWindowID: CGWindowID, n: Int, warmupSec: Double, durationSec: Double) {
    self.cgWindowID = cgWindowID
    self.n = n
    self.warmupSec = warmupSec
    self.durationSec = durationSec
    let staticCount = (n + 1) / 2
    self.samples = (0..<n).map { id in
      WatcherSample(id: id, side: id < staticCount ? "static" : "animated", latencyMs: [])
    }
  }

  func run() async -> RunResult {
    let window: SCWindow
    do {
      window = try await Capture.findWindow(cgWindowID: cgWindowID)
    } catch {
      return RunResult(n: n, warmupSec: warmupSec, durationSec: durationSec,
                       watchers: samples, cpuPctSamples: [], rssBytesSamples: [],
                       errors: [BenchError(n: n, watcherId: -1, message: "window-not-found")])
    }

    // 1. Capture an initial frame to build per-watcher baselines.
    do {
      let frame = try await Capture.captureWindow(window)
      for i in 0..<n {
        let rect = rectFor(watcher: i)
        if let cropped = Capture.crop(frame, toPoints: rect) {
          watcherBaselines.append(Diff.makeBuffer(from: cropped))
        } else {
          watcherBaselines.append(PixelBuffer(width: 1, height: 1, linearRGB: [0, 0, 0]))
          errors.append(BenchError(n: n, watcherId: i, message: "baseline-crop-failed"))
        }
      }
    } catch {
      return RunResult(n: n, warmupSec: warmupSec, durationSec: durationSec,
                       watchers: samples, cpuPctSamples: [], rssBytesSamples: [],
                       errors: [BenchError(n: n, watcherId: -1, message: "baseline-capture-failed")])
    }

    // 2. Warmup ticks (results discarded).
    let warmupTicks = Int(warmupSec.rounded())
    for _ in 0..<warmupTicks {
      _ = await runTick(window: window)
      try? await Task.sleep(nanoseconds: 1_000_000_000)
    }

    // 3. Measurement ticks.
    let measureTicks = Int(durationSec.rounded())
    var prevCPU = Metrics.processCPUSeconds()
    for _ in 0..<measureTicks {
      let tickStart = Date()
      let outcome = await runTick(window: window)
      record(outcome: outcome)
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

  /// One tick: capture the window, fan out per-watcher crop+diff in a TaskGroup.
  /// Nonisolated so the non-Sendable `SCWindow` and `CGImage` stay off-actor —
  /// the actor never observes them, only the Sendable `TickOutcome` that comes back.
  private nonisolated func runTick(window: SCWindow) async -> TickOutcome {
    let frame: CGImage
    do { frame = try await Capture.captureWindow(window) }
    catch {
      return TickOutcome(results: [], captureError: "capture: \(error)")
    }

    // Snapshot baselines off the actor once per tick.
    let baselines = await self.snapshotBaselines()
    let watcherCount = baselines.count
    var rects: [CGRect] = []
    rects.reserveCapacity(watcherCount)
    for i in 0..<watcherCount { rects.append(rectFor(watcher: i)) }

    let results = await withTaskGroup(of: TickResult.self, returning: [TickResult].self) { group in
      for i in 0..<watcherCount {
        let rect = rects[i]
        let baseline = baselines[i]
        group.addTask {
          let t0 = DispatchTime.now().uptimeNanoseconds
          guard let cropped = Capture.crop(frame, toPoints: rect) else {
            return TickResult(id: i, latencyMs: nil)
          }
          let current = Diff.makeBuffer(from: cropped)
          _ = Diff.score(baseline: baseline, current: current)
          let t1 = DispatchTime.now().uptimeNanoseconds
          return TickResult(id: i, latencyMs: Double(t1 - t0) / 1_000_000.0)
        }
      }
      var collected: [TickResult] = []
      collected.reserveCapacity(watcherCount)
      for await r in group { collected.append(r) }
      return collected
    }
    return TickOutcome(results: results, captureError: nil)
  }

  private func snapshotBaselines() -> [PixelBuffer] { watcherBaselines }

  private func record(outcome: TickOutcome) {
    if let msg = outcome.captureError {
      errors.append(BenchError(n: n, watcherId: -1, message: msg))
      return
    }
    for r in outcome.results {
      if let ms = r.latencyMs {
        samples[r.id].latencyMs.append(ms)
      } else {
        errors.append(BenchError(n: n, watcherId: r.id, message: "crop-failed"))
      }
    }
  }

  private nonisolated func rectFor(watcher i: Int) -> CGRect {
    // First ceil(n/2) on static, rest on animated.
    let staticCount = (n + 1) / 2
    return i < staticCount ? staticRect : animatedRect
  }
}
