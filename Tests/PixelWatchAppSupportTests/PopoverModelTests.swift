// Tests/PixelWatchAppSupportTests/PopoverModelTests.swift
import XCTest
@testable import PixelWatchAppSupport

@MainActor
final class PopoverModelTests: XCTestCase {
  func testStartsEmpty() {
    let model = PopoverModel()
    XCTAssertTrue(model.items.isEmpty)
  }

  func testItemsAreMutable() {
    let model = PopoverModel()
    let item = WatcherThumbnailItem(
      id: UUID(),
      name: "Test",
      state: .idle,
      latestFrame: nil
    )
    model.items = [item]
    XCTAssertEqual(model.items.count, 1)
    XCTAssertEqual(model.items[0].name, "Test")
  }

  func testWatcherThumbnailItemIsIdentifiableById() {
    let id = UUID()
    let a = WatcherThumbnailItem(id: id, name: "A", state: .armed, latestFrame: nil)
    let b = WatcherThumbnailItem(id: id, name: "B", state: .idle, latestFrame: nil)
    XCTAssertEqual(a.id, b.id)
  }
}
