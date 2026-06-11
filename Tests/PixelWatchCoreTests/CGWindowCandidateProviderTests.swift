import CoreGraphics
import XCTest
@testable import PixelWatchCore

final class CGWindowCandidateProviderTests: XCTestCase {
  func testParserBuildsCandidateFromCGWindowDictionary() {
    let info = windowInfo(
      windowID: 123,
      processID: 456,
      title: "Build Status",
      bounds: CGRect(x: 10, y: 20, width: 300, height: 200)
    )

    let candidate = CGWindowCandidateParser.parse(
      info,
      bundleIdentifierForProcessID: { pid in
        XCTAssertEqual(pid, 456)
        return "com.example.App"
      }
    )

    XCTAssertEqual(
      candidate,
      WindowCandidate(
        windowID: 123,
        bundleID: "com.example.App",
        title: "Build Status",
        bounds: CGRect(x: 10, y: 20, width: 300, height: 200)
      )
    )
  }

  func testParserDropsWindowWhenRequiredFieldsAreMissing() {
    let valid = windowInfo(windowID: 1, processID: 10, title: "Valid")

    XCTAssertNil(CGWindowCandidateParser.parse(removing(.number, from: valid), bundleIdentifierForProcessID: { _ in "com.example" }))
    XCTAssertNil(CGWindowCandidateParser.parse(removing(.ownerPID, from: valid), bundleIdentifierForProcessID: { _ in "com.example" }))
    XCTAssertNil(CGWindowCandidateParser.parse(removing(.bounds, from: valid), bundleIdentifierForProcessID: { _ in "com.example" }))
    XCTAssertNil(CGWindowCandidateParser.parse(valid, bundleIdentifierForProcessID: { _ in nil }))
  }

  func testParserTreatsMissingWindowNameAsEmptyTitle() {
    let info = removing(.name, from: windowInfo(windowID: 7, processID: 70, title: "Hidden"))

    let candidate = CGWindowCandidateParser.parse(
      info,
      bundleIdentifierForProcessID: { _ in "com.example.Untitled" }
    )

    XCTAssertEqual(
      candidate,
      WindowCandidate(
        windowID: 7,
        bundleID: "com.example.Untitled",
        title: "",
        bounds: CGRect(x: 0, y: 0, width: 100, height: 100)
      )
    )
  }

  func testProviderMapsAndFiltersWindowInfoDictionaries() {
    let included = windowInfo(windowID: 1, processID: 10, title: "Included")
    let missingBundleID = windowInfo(windowID: 2, processID: 20, title: "Missing")

    let provider = CGWindowCandidateProvider(
      windowInfo: { [included, missingBundleID] },
      bundleIdentifierForProcessID: { pid in
        pid == 10 ? "com.example.Included" : nil
      }
    )

    XCTAssertEqual(
      provider.candidates(),
      [
        WindowCandidate(
          windowID: 1,
          bundleID: "com.example.Included",
          title: "Included",
          bounds: CGRect(x: 0, y: 0, width: 100, height: 100)
        ),
      ]
    )
  }

  private enum Field {
    case number
    case ownerPID
    case name
    case bounds

    var key: String {
      switch self {
      case .number:
        String(kCGWindowNumber)
      case .ownerPID:
        String(kCGWindowOwnerPID)
      case .name:
        String(kCGWindowName)
      case .bounds:
        String(kCGWindowBounds)
      }
    }
  }

  private func windowInfo(
    windowID: UInt32,
    processID: pid_t,
    title: String,
    bounds: CGRect = CGRect(x: 0, y: 0, width: 100, height: 100)
  ) -> [String: Any] {
    [
      String(kCGWindowNumber): windowID,
      String(kCGWindowOwnerPID): processID,
      String(kCGWindowName): title,
      String(kCGWindowBounds): [
        "X": bounds.origin.x,
        "Y": bounds.origin.y,
        "Width": bounds.width,
        "Height": bounds.height,
      ],
    ]
  }

  private func removing(_ field: Field, from info: [String: Any]) -> [String: Any] {
    var copy = info
    copy.removeValue(forKey: field.key)
    return copy
  }
}
