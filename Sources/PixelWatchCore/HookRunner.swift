import Darwin
import Foundation

public struct HookResult: Equatable, Sendable {
  public let exit: Int32
  public let stdout: String
  public let stderr: String
  public let timedOut: Bool

  public init(exit: Int32, stdout: String, stderr: String, timedOut: Bool) {
    self.exit = exit
    self.stdout = stdout
    self.stderr = stderr
    self.timedOut = timedOut
  }
}

public protocol HookRunning: Sendable {
  func run(command: String, env: [String: String], timeout: TimeInterval) async -> HookResult
}

public enum HookRunner {
  public static func run(
    command: String,
    env: [String: String],
    timeout: TimeInterval = 30,
    outputLimitBytes: Int = 4096
  ) async -> HookResult {
    var stdoutPipe: [Int32] = [0, 0]
    var stderrPipe: [Int32] = [0, 0]
    guard pipe(&stdoutPipe) == 0, pipe(&stderrPipe) == 0 else {
      return HookResult(exit: 127, stdout: "", stderr: "pipe failed", timedOut: false)
    }

    let stdoutHandle = FileHandle(fileDescriptor: stdoutPipe[0], closeOnDealloc: true)
    let stderrHandle = FileHandle(fileDescriptor: stderrPipe[0], closeOnDealloc: true)
    let stdout = OutputCapture(limitBytes: outputLimitBytes)
    let stderr = OutputCapture(limitBytes: outputLimitBytes)
    let stdoutTask = Task { await stdout.read(from: stdoutHandle) }
    let stderrTask = Task { await stderr.read(from: stderrHandle) }

    var pid = pid_t()
    let spawnResult = spawnShell(
      command: command,
      env: env,
      stdoutWriteFD: stdoutPipe[1],
      stderrWriteFD: stderrPipe[1],
      pid: &pid
    )
    close(stdoutPipe[1])
    close(stderrPipe[1])

    guard spawnResult == 0 else {
      try? stdoutHandle.close()
      try? stderrHandle.close()
      return HookResult(
        exit: 127,
        stdout: "",
        stderr: String(cString: strerror(spawnResult)),
        timedOut: false
      )
    }

    let waitResult = await waitForExit(pid: pid, timeout: timeout)
    let timedOut = waitResult.timedOut

    let stdoutText = await stdoutTask.value
    let stderrText = await stderrTask.value
    return HookResult(
      exit: waitResult.exit,
      stdout: stdoutText,
      stderr: stderrText,
      timedOut: timedOut
    )
  }

  private static func spawnShell(
    command: String,
    env: [String: String],
    stdoutWriteFD: Int32,
    stderrWriteFD: Int32,
    pid: inout pid_t
  ) -> Int32 {
    var actions: posix_spawn_file_actions_t?
    var attributes: posix_spawnattr_t?
    posix_spawn_file_actions_init(&actions)
    posix_spawnattr_init(&attributes)
    defer {
      posix_spawn_file_actions_destroy(&actions)
      posix_spawnattr_destroy(&attributes)
    }

    posix_spawn_file_actions_adddup2(&actions, stdoutWriteFD, STDOUT_FILENO)
    posix_spawn_file_actions_adddup2(&actions, stderrWriteFD, STDERR_FILENO)
    posix_spawn_file_actions_addclose(&actions, stdoutWriteFD)
    posix_spawn_file_actions_addclose(&actions, stderrWriteFD)
    posix_spawn_file_actions_addchdir_np(
      &actions,
      FileManager.default.homeDirectoryForCurrentUser.path
    )

    let flags = Int16(POSIX_SPAWN_SETPGROUP)
    posix_spawnattr_setflags(&attributes, flags)
    posix_spawnattr_setpgroup(&attributes, 0)

    let argv = makeCStringArray(["/bin/sh", "-c", command])
    let environment = ProcessInfo.processInfo.environment.merging(env) { _, new in new }
    let envp = makeCStringArray(environment.map { "\($0.key)=\($0.value)" })
    defer {
      freeCStringArray(argv)
      freeCStringArray(envp)
    }

    return posix_spawn(&pid, "/bin/sh", &actions, &attributes, argv, envp)
  }

  private static func waitForExit(pid: pid_t, timeout: TimeInterval) async -> (exit: Int32, timedOut: Bool) {
    let deadline = ContinuousClock.now + .nanoseconds(Int64(max(0, timeout) * 1_000_000_000))
    var status: Int32 = 0
    while ContinuousClock.now < deadline {
      let result = waitpid(pid, &status, WNOHANG)
      if result == pid {
        return (exitStatus(from: status), false)
      }
      try? await Task.sleep(nanoseconds: 10_000_000)
    }

    terminateProcessGroup(pid: pid, signal: SIGTERM)
    let killDeadline = ContinuousClock.now + .milliseconds(200)
    while ContinuousClock.now < killDeadline {
      let result = waitpid(pid, &status, WNOHANG)
      if result == pid {
        return (exitStatus(from: status), true)
      }
      try? await Task.sleep(nanoseconds: 10_000_000)
    }

    terminateProcessGroup(pid: pid, signal: SIGKILL)
    waitpid(pid, &status, 0)
    return (exitStatus(from: status), true)
  }

  private static func terminateProcessGroup(pid: pid_t, signal: Int32 = SIGTERM) {
    kill(-pid, signal)
  }

  private static func exitStatus(from status: Int32) -> Int32 {
    if waitStatus(status) == 0 {
      return (status >> 8) & 0xff
    }
    if waitStatus(status) != 0x7f {
      return 128 + waitStatus(status)
    }
    return status
  }

  private static func waitStatus(_ status: Int32) -> Int32 {
    status & 0x7f
  }
}

public struct LiveHookRunner: HookRunning {
  public init() {}

  public func run(command: String, env: [String: String], timeout: TimeInterval) async -> HookResult {
    await HookRunner.run(command: command, env: env, timeout: timeout)
  }
}

private func makeCStringArray(_ values: [String]) -> [UnsafeMutablePointer<CChar>?] {
  values.map { strdup($0) } + [nil]
}

private func freeCStringArray(_ values: [UnsafeMutablePointer<CChar>?]) {
  for value in values {
    free(value)
  }
}

private actor OutputCapture {
  private let limitBytes: Int

  init(limitBytes: Int) {
    self.limitBytes = limitBytes
  }

  func read(from handle: FileHandle) async -> String {
    var buffer = Data()
    while !Task.isCancelled {
      let chunk = handle.availableData
      if chunk.isEmpty {
        break
      }
      if buffer.count < limitBytes {
        buffer.append(chunk.prefix(limitBytes - buffer.count))
      }
    }
    return String(decoding: buffer, as: UTF8.self)
  }
}
