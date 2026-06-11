import XCTest
@testable import PixelWatchCore

final class TitleMatchTests: XCTestCase {
  func testLiteralValueExtractsInnerString() {
    XCTAssertEqual(TitleMatch.exact("Xcode").literalValue, "Xcode")
    XCTAssertEqual(TitleMatch.contains("Build").literalValue, "Build")
    XCTAssertEqual(TitleMatch.regex("^Build.*").literalValue, "^Build.*")
  }
}
