import CoreGraphics
import XCTest
@testable import PixelWatchCore

final class WindowResolverTests: XCTestCase {
  func testResolvePrefersLiveWindowIDHint() {
    let hinted = candidate(id: 42, bundleID: "com.other", title: "Other")
    let titleMatch = candidate(id: 9, bundleID: "com.example", title: "Builds")
    let binding = WindowBinding(
      bundleID: "com.example",
      titleMatch: .exact("Builds"),
      windowIDHint: 42,
      lastKnownBounds: nil
    )

    XCTAssertEqual(WindowResolver.resolve(binding: binding, candidates: [titleMatch, hinted]), hinted)
  }

  func testResolveFallsBackWhenWindowIDHintIsStale() {
    let match = candidate(id: 9, bundleID: "com.example", title: "Builds")
    let binding = WindowBinding(
      bundleID: "com.example",
      titleMatch: .exact("Builds"),
      windowIDHint: 42,
      lastKnownBounds: nil
    )

    XCTAssertEqual(WindowResolver.resolve(binding: binding, candidates: [match]), match)
  }

  func testResolveSupportsContainsAndRegexTitleMatching() {
    let containsMatch = candidate(id: 1, bundleID: "com.example", title: "Main Branch Builds")
    let regexMatch = candidate(id: 2, bundleID: "com.example", title: "Deploy #123")

    XCTAssertEqual(
      WindowResolver.resolve(
        binding: WindowBinding(bundleID: "com.example", titleMatch: .contains("Branch")),
        candidates: [containsMatch]
      ),
      containsMatch
    )
    XCTAssertEqual(
      WindowResolver.resolve(
        binding: WindowBinding(bundleID: "com.example", titleMatch: .regex(#"Deploy #\d+"#)),
        candidates: [regexMatch]
      ),
      regexMatch
    )
  }

  func testResolvePrefersCandidateWithGreatestOverlapToLastKnownBounds() {
    let weakOverlap = candidate(
      id: 1,
      bundleID: "com.example",
      title: "Builds",
      bounds: CGRect(x: 900, y: 900, width: 200, height: 200)
    )
    let strongOverlap = candidate(
      id: 2,
      bundleID: "com.example",
      title: "Builds",
      bounds: CGRect(x: 10, y: 10, width: 200, height: 200)
    )
    let binding = WindowBinding(
      bundleID: "com.example",
      titleMatch: .exact("Builds"),
      lastKnownBounds: CGRect(x: 0, y: 0, width: 200, height: 200)
    )

    XCTAssertEqual(
      WindowResolver.resolve(binding: binding, candidates: [weakOverlap, strongOverlap]),
      strongOverlap
    )
  }

  func testResolveReturnsNilWhenNoCandidatesMatch() {
    let binding = WindowBinding(bundleID: "com.example", titleMatch: .exact("Builds"))
    let otherBundle = candidate(id: 1, bundleID: "com.other", title: "Builds")
    let otherTitle = candidate(id: 2, bundleID: "com.example", title: "Dashboard")

    XCTAssertNil(WindowResolver.resolve(binding: binding, candidates: [otherBundle, otherTitle]))
  }

  private func candidate(
    id: UInt32,
    bundleID: String,
    title: String,
    bounds: CGRect = CGRect(x: 0, y: 0, width: 100, height: 100)
  ) -> WindowCandidate {
    WindowCandidate(windowID: id, bundleID: bundleID, title: title, bounds: bounds)
  }
}
