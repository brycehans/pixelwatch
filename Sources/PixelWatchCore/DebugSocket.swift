// DebugSocket — bidirectional JSONL bridge between the EventBus and unix-domain socket clients.
//
// TODO: Add a Settings toggle so this can be disabled in production builds. For now it starts
// unconditionally in applicationDidFinishLaunching.

import Darwin
import Foundation

// MARK: - Public error type

public enum DebugSocketError: Error {
  case socketCreateFailed(errno: Int32)
  case pathTooLong
  case bindFailed(errno: Int32)
  case listenFailed(errno: Int32)
}

// MARK: - Commands sent in from socket clients

/// Imperative commands a socket client can send to drive the running app.
/// Wire format is `{"cmd":"<case>"}` per line; coordinate commands also carry `"x"` and `"y"`.
public enum DebugCommand: Codable, Sendable, Equatable {
  case newWatcher
  case quit
  case dropAt(x: Double, y: Double)
  case drawBegin(x: Double, y: Double)
  case drawMove(x: Double, y: Double)
  case drawEnd(x: Double, y: Double)
  case drawCancel
  case drawRect(startX: Double, startY: Double, endX: Double, endY: Double)

  private enum CodingKeys: String, CodingKey { case cmd, x, y, startX, startY, endX, endY }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let cmd = try c.decode(String.self, forKey: .cmd)
    switch cmd {
    case "newWatcher": self = .newWatcher
    case "quit": self = .quit
    case "dropAt":
      let x = try c.decode(Double.self, forKey: .x)
      let y = try c.decode(Double.self, forKey: .y)
      self = .dropAt(x: x, y: y)
    case "drawBegin":
      let x = try c.decode(Double.self, forKey: .x)
      let y = try c.decode(Double.self, forKey: .y)
      self = .drawBegin(x: x, y: y)
    case "drawMove":
      let x = try c.decode(Double.self, forKey: .x)
      let y = try c.decode(Double.self, forKey: .y)
      self = .drawMove(x: x, y: y)
    case "drawEnd":
      let x = try c.decode(Double.self, forKey: .x)
      let y = try c.decode(Double.self, forKey: .y)
      self = .drawEnd(x: x, y: y)
    case "drawCancel":
      self = .drawCancel
    case "drawRect":
      let startX = try c.decode(Double.self, forKey: .startX)
      let startY = try c.decode(Double.self, forKey: .startY)
      let endX = try c.decode(Double.self, forKey: .endX)
      let endY = try c.decode(Double.self, forKey: .endY)
      self = .drawRect(startX: startX, startY: startY, endX: endX, endY: endY)
    default:
      throw DecodingError.dataCorruptedError(forKey: .cmd, in: c, debugDescription: "Unknown command: \(cmd)")
    }
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .newWatcher: try c.encode("newWatcher", forKey: .cmd)
    case .quit: try c.encode("quit", forKey: .cmd)
    case let .dropAt(x, y):
      try c.encode("dropAt", forKey: .cmd)
      try c.encode(x, forKey: .x)
      try c.encode(y, forKey: .y)
    case let .drawBegin(x, y):
      try c.encode("drawBegin", forKey: .cmd)
      try c.encode(x, forKey: .x)
      try c.encode(y, forKey: .y)
    case let .drawMove(x, y):
      try c.encode("drawMove", forKey: .cmd)
      try c.encode(x, forKey: .x)
      try c.encode(y, forKey: .y)
    case let .drawEnd(x, y):
      try c.encode("drawEnd", forKey: .cmd)
      try c.encode(x, forKey: .x)
      try c.encode(y, forKey: .y)
    case .drawCancel:
      try c.encode("drawCancel", forKey: .cmd)
    case let .drawRect(startX, startY, endX, endY):
      try c.encode("drawRect", forKey: .cmd)
      try c.encode(startX, forKey: .startX)
      try c.encode(startY, forKey: .startY)
      try c.encode(endX, forKey: .endX)
      try c.encode(endY, forKey: .endY)
    }
  }
}

// MARK: - Per-client state (not an actor; only touched from inside the DebugSocket actor)

private final class ClientConnection: @unchecked Sendable {
  let fd: Int32
  var readThread: Thread?

  init(fd: Int32) {
    self.fd = fd
  }
}

// MARK: - DebugSocket actor

public actor DebugSocket {

  // MARK: Public API

  public static func defaultPath() -> URL {
    FileManager.default
      .homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/PixelWatch/bus.sock")
  }

  public init(
    bus: EventBus,
    path: URL = DebugSocket.defaultPath(),
    commandHandler: @Sendable @escaping (DebugCommand) -> Void = { _ in }
  ) {
    self.bus = bus
    self.path = path
    self.commandHandler = commandHandler
  }

  // Starts the unix-domain listener and the bus-fanout task.
  public func start() throws {
    try FileManager.default.createDirectory(
      at: path.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    if FileManager.default.fileExists(atPath: path.path) {
      try FileManager.default.removeItem(at: path)
    }

    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw DebugSocketError.socketCreateFailed(errno: errno) }

    // Build the sockaddr_un.
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = path.path.utf8CString
    guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
      Darwin.close(fd)
      throw DebugSocketError.pathTooLong
    }
    let sunPathCapacity = MemoryLayout.size(ofValue: addr.sun_path)
    withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
      ptr.withMemoryRebound(to: CChar.self, capacity: sunPathCapacity) { dst in
        _ = pathBytes.withUnsafeBufferPointer { src in
          memcpy(dst, src.baseAddress!, src.count)
        }
      }
    }

    let bindResult = withUnsafePointer(to: &addr) { ptr in
      ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
        Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard bindResult == 0 else {
      let e = errno
      Darwin.close(fd)
      throw DebugSocketError.bindFailed(errno: e)
    }

    guard Darwin.listen(fd, 8) == 0 else {
      let e = errno
      Darwin.close(fd)
      throw DebugSocketError.listenFailed(errno: e)
    }

    serverFD = fd

    // Subscribe to the bus and fan out every event to all connected clients.
    let busRef = bus
    fanoutTask = Task { [weak self] in
      let stream = await busRef.subscribe()
      var iterator = stream.makeAsyncIterator()
      while !Task.isCancelled, let event = await iterator.next() {
        await self?.broadcast(event)
      }
    }

    // Background thread: loops accept() and hands accepted fds to the actor.
    let thread = Thread { [weak self] in
      guard let self else { return }
      while true {
        let clientFD = Darwin.accept(fd, nil, nil)
        if clientFD < 0 {
          // EBADF / EINVAL means the server socket was closed — time to stop.
          if errno == EBADF || errno == EINVAL { return }
          continue
        }
        Task { await self.adopt(clientFD: clientFD) }
      }
    }
    thread.name = "PixelWatch.DebugSocket.accept"
    thread.start()
    acceptThread = thread
  }

  // Tears down the socket, all client connections, and the fanout task.
  public func stop() {
    fanoutTask?.cancel()
    fanoutTask = nil
    if serverFD >= 0 {
      Darwin.close(serverFD)
      serverFD = -1
    }
    for (fd, _) in clients {
      Darwin.close(fd)
    }
    clients.removeAll()
    try? FileManager.default.removeItem(at: path)
    acceptThread = nil
  }

  // MARK: Private state

  private let bus: EventBus
  private let path: URL
  private let commandHandler: @Sendable (DebugCommand) -> Void
  private var serverFD: Int32 = -1
  private var acceptThread: Thread?
  private var clients: [Int32: ClientConnection] = [:]
  private var fanoutTask: Task<Void, Never>?

  private let encoder: JSONEncoder = {
    let e = JSONEncoder()
    e.outputFormatting = []  // no pretty printing — must be single line
    return e
  }()

  private let decoder = JSONDecoder()

  // MARK: Internal helpers

  // Called from the accept-thread's Task to register a new client.
  private func adopt(clientFD: Int32) {
    // Prevent SIGPIPE on write to a disconnected client; use SO_NOSIGPIPE (macOS).
    var one: Int32 = 1
    setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

    let conn = ClientConnection(fd: clientFD)
    clients[clientFD] = conn

    // Capture weak refs / value copies to avoid actor re-entrancy in the thread body.
    let busRef = bus
    let decoderRef = decoder
    let commandHandlerRef = commandHandler

    let thread = Thread {
      var buffer = Data()
      var readBuf = [UInt8](repeating: 0, count: 4096)

      while true {
        let n = Darwin.read(clientFD, &readBuf, readBuf.count)
        if n <= 0 { break }  // EOF or error — disconnect
        buffer.append(contentsOf: readBuf[..<n])

        // Extract complete newline-terminated lines.
        while let nlIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
          let lineData = buffer[..<nlIndex]
          buffer.removeSubrange(...nlIndex)

          if lineData.isEmpty { continue }

          // Decode on the thread, then publish via Task hop.
          // Try PixelWatchEvent first (the "publish onto the bus" path);
          // fall back to DebugCommand for imperative client → app commands.
          let payload = Data(lineData)
          if let event = try? decoderRef.decode(PixelWatchEvent.self, from: payload) {
            Task { await busRef.publish(event) }
          } else if let command = try? decoderRef.decode(DebugCommand.self, from: payload) {
            commandHandlerRef(command)
          } else {
            let msg = "[DebugSocket] could not decode line: \(String(data: payload, encoding: .utf8) ?? "<non-UTF8>")\n"
            if let d = msg.data(using: .utf8) {
              FileHandle.standardError.write(d)
            }
          }
        }
      }

      // EOF: ask the actor to remove this client.
      Task { [weak self] in await self?.removeClient(fd: clientFD) }
    }
    thread.name = "PixelWatch.DebugSocket.read[\(clientFD)]"
    thread.start()
    conn.readThread = thread
  }

  // Send an event to all connected clients as a JSONL line.
  // Pixel buffers are stripped to {width, height, linearRGB:""} before encoding —
  // raw frame data is far too large to fan out over the socket at capture frequency.
  private func broadcast(_ event: PixelWatchEvent) {
    guard !clients.isEmpty else { return }
    guard
      let data = try? encoder.encode(event.strippedForBroadcast),
      var line = String(data: data, encoding: .utf8)
    else { return }
    line += "\n"

    var deadFDs: [Int32] = []
    line.withCString { ptr in
      let len = strlen(ptr)
      for fd in clients.keys {
        let written = Darwin.write(fd, ptr, len)
        if written < 0 {
          deadFDs.append(fd)
        }
      }
    }
    for fd in deadFDs {
      removeClient(fd: fd)
    }
  }

  // Remove a client (called both on write failure and EOF from the read thread).
  private func removeClient(fd: Int32) {
    if clients.removeValue(forKey: fd) != nil {
      Darwin.close(fd)
    }
  }
}

// MARK: - Broadcast-safe event stripping

private extension PixelWatchEvent {
  /// Returns the event with all PixelBuffer payloads replaced by empty stubs
  /// (width/height preserved, linearRGB empty). Keeps wire size tiny while
  /// still letting clients see frame dimensions and diff scores.
  var strippedForBroadcast: PixelWatchEvent {
    switch self {
    case let .armed(watcherID, baseline):
      return .armed(watcherID: watcherID, baseline: baseline.stub)
    case let .frameCaptured(watcherID, frame, at):
      return .frameCaptured(watcherID: watcherID, frame: frame.stub, at: at)
    case let .diffComputed(watcherID, score, frame):
      return .diffComputed(watcherID: watcherID, score: score, frame: frame.stub)
    case let .thresholdExceeded(watcherID, score, frame):
      return .thresholdExceeded(watcherID: watcherID, score: score, frame: frame.stub)
    case .windowVanished, .hookStarted, .hookFinished, .paused, .errored,
         .popoverShowRequested, .popoverHideRequested:
      return self
    }
  }
}

private extension PixelBuffer {
  var stub: PixelBuffer { PixelBuffer(width: width, height: height, linearRGB: []) }
}
