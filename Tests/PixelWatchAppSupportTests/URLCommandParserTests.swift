import Foundation
import XCTest
@testable import PixelWatchAppSupport

final class URLCommandParserTests: XCTestCase {

  func testParsesShowURL() {
    let url = URL(string: "pixelwatch://show")!
    XCTAssertEqual(URLCommandParser.parse(url), .showPopover)
  }

  func testParsesHideURL() {
    let url = URL(string: "pixelwatch://hide")!
    XCTAssertEqual(URLCommandParser.parse(url), .hidePopover)
  }

  func testParsesArmURL() {
    let id = UUID()
    let url = URL(string: "pixelwatch://arm?id=\(id.uuidString)")!
    XCTAssertEqual(URLCommandParser.parse(url), .arm(id: id))
  }

  func testParsesPauseURL() {
    let id = UUID()
    let url = URL(string: "pixelwatch://pause?id=\(id.uuidString)")!
    XCTAssertEqual(URLCommandParser.parse(url), .pause(id: id))
  }

  func testParsesDeleteURL() {
    let id = UUID()
    let url = URL(string: "pixelwatch://delete?id=\(id.uuidString)")!
    XCTAssertEqual(URLCommandParser.parse(url), .delete(id: id))
  }

  func testReturnsNilForUnknownAction() {
    let id = UUID()
    let url = URL(string: "pixelwatch://frobnicate?id=\(id.uuidString)")!
    XCTAssertNil(URLCommandParser.parse(url))
  }

  func testReturnsNilForMissingID() {
    let url = URL(string: "pixelwatch://arm")!
    XCTAssertNil(URLCommandParser.parse(url))
  }

  func testReturnsNilForMalformedID() {
    let url = URL(string: "pixelwatch://arm?id=not-a-uuid")!
    XCTAssertNil(URLCommandParser.parse(url))
  }
}
