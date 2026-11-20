import Foundation
import OmnigentCoreFFI
import OmnigentUIComponents
import Testing

@testable import OmnigentAppUI

/// A Canvas card's PR, as the web's card links it.
@Suite("Canvas card pull requests")
@MainActor
struct CanvasPullRequestMappingTests {
  private func row(_ url: String, title: String? = "Ship it", prefix: String = "#")
    -> RowPullRequest
  {
    RowPullRequest(
      number: 212, status: .merged, checkedAt: nil, url: url, title: title, numberPrefix: prefix,
      requestName: prefix == "!" ? "merge request" : nil)
  }

  @Test("the link reads its prefix, number and title, and names its provider's request")
  func link() throws {
    let link = try #require(CanvasMapping.pullRequest(row("https://example.com/org/app/pull/212")))
    #expect(link.text == "#212 Ship it")
    #expect(link.tooltip == "Ship it (merged)")
    #expect(link.accessibilityLabel == "Open pull request #212")
    let gitlab = try #require(
      CanvasMapping.pullRequest(
        row("https://example.com/org/app/-/merge_requests/212", prefix: "!")))
    #expect(gitlab.text == "!212 Ship it")
    #expect(gitlab.accessibilityLabel == "Open merge request !212")
    let untitled = try #require(
      CanvasMapping.pullRequest(row("https://example.com/org/app/pull/212", title: nil)))
    #expect(untitled.text == "#212")
  }

  @Test("only an https page is linked")
  func httpsOnly() {
    #expect(CanvasMapping.pullRequest(row("http://example.com/org/app/pull/212")) == nil)
    #expect(CanvasMapping.pullRequest(row("")) == nil)
  }
}
