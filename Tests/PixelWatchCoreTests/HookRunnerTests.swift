import XCTest
@testable import PixelWatchCore

final class HookRunnerTests: XCTestCase {
  func testRunCapturesStdoutStderrAndExitCode() async {
    let result = await HookRunner.run(
      command: "printf 'hello'; printf 'warn' >&2; exit 7",
      env: [:],
      timeout: 2
    )

    XCTAssertEqual(result.exit, 7)
    XCTAssertEqual(result.stdout, "hello")
    XCTAssertEqual(result.stderr, "warn")
    XCTAssertFalse(result.timedOut)
  }

  func testRunPassesEnvironmentAndUsesHomeWorkingDirectory() async {
    let result = await HookRunner.run(
      command: "printf '%s|%s' \"$WATCH_NAME\" \"$PWD\"",
      env: ["WATCH_NAME": "CI badge"],
      timeout: 2
    )

    XCTAssertEqual(result.exit, 0)
    XCTAssertEqual(result.stdout, "CI badge|\(FileManager.default.homeDirectoryForCurrentUser.path)")
    XCTAssertEqual(result.stderr, "")
    XCTAssertFalse(result.timedOut)
  }

  func testRunCapsOutputStreams() async {
    let result = await HookRunner.run(
      command: "yes x | head -c 5000; yes y | head -c 5000 >&2",
      env: [:],
      timeout: 2
    )

    XCTAssertEqual(result.exit, 0)
    XCTAssertEqual(result.stdout.utf8.count, 4096)
    XCTAssertEqual(result.stderr.utf8.count, 4096)
    XCTAssertFalse(result.timedOut)
  }

  func testRunTimesOutHungCommand() async {
    let start = ContinuousClock.now

    let result = await HookRunner.run(
      command: "sleep 5",
      env: [:],
      timeout: 0.2
    )

    XCTAssertTrue(result.timedOut)
    XCTAssertNotEqual(result.exit, 0)
    XCTAssertLessThan(start.duration(to: .now), .seconds(3))
  }
}
