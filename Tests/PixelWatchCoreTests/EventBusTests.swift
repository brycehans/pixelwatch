import XCTest
@testable import PixelWatchCore

final class EventBusTests: XCTestCase {
  func testPublishFansOutToEveryActiveSubscriber() async {
    let bus = EventBus()
    var first = await bus.subscribe().makeAsyncIterator()
    var second = await bus.subscribe().makeAsyncIterator()
    let watcherID = UUID()
    let event = PixelWatchEvent.paused(watcherID: watcherID, reason: .userPaused)

    await bus.publish(event)

    let firstEvent = await first.next()
    let secondEvent = await second.next()
    XCTAssertEqual(firstEvent, event)
    XCTAssertEqual(secondEvent, event)
  }
}
