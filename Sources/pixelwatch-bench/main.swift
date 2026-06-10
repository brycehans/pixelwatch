import Foundation
import AppKit
import Darwin

// MARK: - Types

struct Options {
  var ns: [Int] = [1, 5, 20, 50]
  var durationSec: Double = 60
  var warmupSec: Double = 5
  var outPath: String = "bench-\(Int(Date().timeIntervalSince1970)).json"
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
    var buf = [UInt8](repeating: 0, count: size)
    sysctlbyname(name, &buf, &size, nil, 0)
    // Drop trailing NUL(s) before decoding as UTF-8.
    while buf.last == 0 { buf.removeLast() }
    return String(decoding: buf, as: UTF8.self)
  }
}

struct Report: Codable {
  let startedAt: String
  let host: HostInfo
  let runs: [RunResult]
}

// MARK: - Arg parsing

func parseArgs(_ args: ArraySlice<String>) -> Options {
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

// MARK: - Top-level entry (Swift 6: implicitly @MainActor)

let opts = parseArgs(CommandLine.arguments.dropFirst())

let app = NSApplication.shared
app.setActivationPolicy(.regular)

let testWindow = TestWindow()
testWindow.show()

guard let cgWindowID = testWindow.waitForCGWindowID() else {
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

testWindow.close()

let report = Report(
  startedAt: ISO8601DateFormatter().string(from: Date()),
  host: HostInfo.collect(),
  runs: runs
)

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
let json = try encoder.encode(report)
try json.write(to: URL(fileURLWithPath: opts.outPath))
FileHandle.standardError.write(Data("wrote \(opts.outPath)\n".utf8))
