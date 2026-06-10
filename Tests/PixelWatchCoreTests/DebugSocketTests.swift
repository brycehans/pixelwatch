import Darwin
import Foundation
import XCTest

@testable import PixelWatchCore

final class DebugSocketTests: XCTestCase {

  override func setUp() {
    super.setUp()
    // Suppress SIGPIPE process-wide so that writes to disconnected sockets return
    // EPIPE (errno) instead of killing the process.
    signal(SIGPIPE, SIG_IGN)
  }

  // Round-trip smoke test:
  //   1. Publish an event from the bus → expect to see JSONL on a connected client fd.
  //   2. Inject a JSONL line from the client fd → expect the event to appear on the bus.
  func testRoundTripsBusEventsOverUnixSocket() async throws {
    // Use /tmp directly — the default temp dir path plus a UUID filename
    // exceeds the 104-byte sun_path limit for unix-domain sockets on macOS.
    let tmpPath = URL(fileURLWithPath: "/tmp/pw-\(UUID().uuidString.prefix(8)).sock")
    defer { try? FileManager.default.removeItem(at: tmpPath) }

    let bus = EventBus()
    let socket = DebugSocket(bus: bus, path: tmpPath)
    try await socket.start()
    defer { Task { await socket.stop() } }

    // Give the accept thread a moment to reach accept().
    try await Task.sleep(nanoseconds: 50_000_000)  // 50 ms

    // ---- Connect a raw POSIX client ----
    let clientFD = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    XCTAssertGreaterThanOrEqual(clientFD, 0, "Failed to create client socket")
    defer { Darwin.close(clientFD) }

    // Suppress SIGPIPE on the client socket as well.
    var one: Int32 = 1
    setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = tmpPath.path.utf8CString
    let sunPathCapacity = MemoryLayout.size(ofValue: addr.sun_path)
    withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
      ptr.withMemoryRebound(to: CChar.self, capacity: sunPathCapacity) { dst in
        _ = pathBytes.withUnsafeBufferPointer { src in
          memcpy(dst, src.baseAddress!, src.count)
        }
      }
    }
    let connectResult = withUnsafePointer(to: &addr) { ptr in
      ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
        Darwin.connect(clientFD, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    XCTAssertEqual(connectResult, 0, "connect() failed: errno=\(errno)")

    // Give the actor time to adopt the client.
    try await Task.sleep(nanoseconds: 50_000_000)  // 50 ms

    // ---- 1. Bus → client (fanout) ----
    let watcherA = UUID()
    await bus.publish(.errored(watcherID: watcherA, message: "from-bus"))

    let receivedLine = try await readLineWithTimeout(clientFD, seconds: 2.0)
    XCTAssertTrue(
      receivedLine.contains("\"type\":\"errored\""),
      "Expected type=errored in: \(receivedLine)"
    )
    XCTAssertTrue(
      receivedLine.contains("from-bus"),
      "Expected message in: \(receivedLine)"
    )

    // ---- 2. Client → bus (injection) ----
    // Subscribe to the bus before sending so we don't miss the published event.
    let busReader = EventReader(stream: await bus.subscribe())
    await busReader.start()

    let watcherB = UUID()
    let injectedJSON =
      "{\"type\":\"paused\",\"watcherID\":\"\(watcherB.uuidString)\",\"reason\":\"userPaused\"}"
    let injectedLine = injectedJSON + "\n"
    let writeResult = injectedLine.withCString { ptr in
      Darwin.write(clientFD, ptr, strlen(ptr))
    }
    XCTAssertGreaterThan(writeResult, 0, "write() to socket failed: errno=\(errno)")

    // Wait for the injected event to appear on the bus (up to 2 s).
    let received = await busReader.next(
      timeoutNanoseconds: 2_000_000_000,
      matching: { event in
        if case let .paused(id, reason) = event, id == watcherB, reason == .userPaused {
          return true
        }
        return false
      }
    )
    XCTAssertNotNil(received, "Expected to observe injected .paused event on the bus")
  }

  // MARK: - Helpers

  /// Reads from `fd` in non-blocking mode (polling with Task.sleep) until a newline is found
  /// or the timeout elapses. Returns the line without the trailing newline.
  @discardableResult
  private func readLineWithTimeout(_ fd: Int32, seconds: TimeInterval) async throws -> String {
    // Set non-blocking so read() returns immediately when no data is available.
    let flags = fcntl(fd, F_GETFL)
    _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    defer { _ = fcntl(fd, F_SETFL, flags) }  // restore on exit

    var buffer = Data()
    let deadline = ContinuousClock.now + .seconds(seconds)
    var readBuf = [UInt8](repeating: 0, count: 4096)

    while ContinuousClock.now < deadline {
      let n = Darwin.read(fd, &readBuf, readBuf.count)
      if n > 0 {
        buffer.append(contentsOf: readBuf[..<n])
        if let nlIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
          let lineData = buffer[..<nlIndex]
          return String(data: Data(lineData), encoding: .utf8) ?? ""
        }
      } else if n < 0 && errno != EAGAIN && errno != EWOULDBLOCK {
        break  // real read error
      }
      try await Task.sleep(nanoseconds: 10_000_000)  // 10 ms poll
    }
    XCTFail("Timed out waiting for a JSONL line from the socket")
    return ""
  }
}
