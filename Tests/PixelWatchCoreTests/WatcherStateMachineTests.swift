import XCTest
@testable import PixelWatchCore

final class WatcherStateMachineTests: XCTestCase {
  func testThresholdExceededMovesArmedWatcherToTriggered() {
    let watcherID = UUID()
    var machine = WatcherStateMachine(watcherID: watcherID, state: .armed)
    let frame = PixelBuffer(width: 1, height: 1, linearRGB: [1, 1, 1])

    let result = machine.apply(.thresholdExceeded(watcherID: watcherID, score: 0.1, frame: frame))

    XCTAssertEqual(result.newState, .triggered)
    XCTAssertEqual(result.emittedEvents, [])
  }

  func testWindowVanishedMovesArmedWatcherToTriggered() {
    let watcherID = UUID()
    var machine = WatcherStateMachine(watcherID: watcherID, state: .armed)

    let result = machine.apply(.windowVanished(watcherID: watcherID, reason: .windowClosed))

    XCTAssertEqual(result.newState, .triggered)
    XCTAssertEqual(result.emittedEvents, [])
  }

  func testPauseMovesArmedWatcherToIdle() {
    let watcherID = UUID()
    var machine = WatcherStateMachine(watcherID: watcherID, state: .armed)

    let result = machine.apply(.paused(watcherID: watcherID, reason: .userPaused))

    XCTAssertEqual(result.newState, .idle)
    XCTAssertEqual(result.emittedEvents, [])
  }

  func testSensitivityThresholdMappingMatchesContextReferencePoints() {
    XCTAssertEqual(DecideStage.threshold(forSensitivity: 1), 0.001, accuracy: 0.0000001)
    XCTAssertEqual(DecideStage.threshold(forSensitivity: 0), 0.2, accuracy: 0.0000001)
    XCTAssertEqual(DecideStage.threshold(forSensitivity: 0.7), 0.004901274, accuracy: 0.0000001)
  }
}
