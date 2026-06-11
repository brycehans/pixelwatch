import Foundation
import XCTest
@testable import PixelWatchCore

final class PixelWatchEventCodableTests: XCTestCase {

  func testPopoverShowRequestedRoundTripsThroughCodable() throws {
    try assertRoundTrip(.popoverShowRequested)
  }

  func testPopoverHideRequestedRoundTripsThroughCodable() throws {
    try assertRoundTrip(.popoverHideRequested)
  }

  private func assertRoundTrip(_ event: PixelWatchEvent) throws {
    let data = try JSONEncoder().encode(event)
    let decoded = try JSONDecoder().decode(PixelWatchEvent.self, from: data)
    XCTAssertEqual(decoded, event)
  }
}
