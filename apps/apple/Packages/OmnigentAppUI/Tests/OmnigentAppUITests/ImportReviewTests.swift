import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents
import OmnigentViewTesting
import OmnigentViewTextReading
import SwiftUI
import Testing

@testable import OmnigentAppUI

/// The import review after desktop onboarding hosts on this Mac (`import_review`): asked for
/// once per server, remembered per host on this device, and drawn as the web's review.
@MainActor
@Suite("Import review", .serialized)
struct ImportReviewTests {
  @Test("onboarding asks a server's window for the review once, whatever its URL's slash")
  func requests() {
    let requests = ImportReviewRequests()
    requests.request("https://omnigent.example.com/")
    #expect(requests.isRequested("https://OMNIGENT.example.com"))
    requests.done("https://omnigent.example.com")
    #expect(!requests.isRequested("https://omnigent.example.com/"))
  }

  @Test("a host reviewed on this device isn't reviewed again")
  func memory() throws {
    let defaults = try #require(UserDefaults(suiteName: "import-review-tests"))
    defaults.removePersistentDomain(forName: "import-review-tests")
    #expect(!ImportReviewMemory.isReviewed("host_a", defaults: defaults))
    ImportReviewMemory.markReviewed("host_a", defaults: defaults)
    #expect(ImportReviewMemory.isReviewed("host_a", defaults: defaults))
    #expect(ImportReviewMemory.key("host_a") == "omnigent:imports-reviewed:host_a")
  }

  @Test("the review shows each harness's credential and what it carries over")
  func view() throws {
    let review = ImportReview(
      hostName: "Work Mac", online: true,
      harnesses: [
        ImportReviewHarness(
          harness: "claude-native", label: "Claude Code", credential: "Signed in",
          mcpServers: ["docs"], skills: ["/review"], plugins: [], notices: []),
        ImportReviewHarness(
          harness: "codex-native", label: "Codex", credential: nil, mcpServers: [],
          skills: ["$plan"], plugins: [], notices: ["Couldn't read plugins from this machine."]),
      ])
    let phase = ImportReviewStore.Phase.loaded(review).view
    let screen = OffscreenWindow(
      ImportReviewView(phase: phase, seeMore: {}, confirm: {}), width: 520, height: 480)
    defer { screen.close() }
    for text in [
      "Found in your harnesses on Work Mac. These carry over automatically.", "Claude Code",
      "Codex", "Signed in", "Detected", "docs", "/review",
    ] {
      #expect(try screen.shows(text), "\(text)")
    }
    let empty = OffscreenWindow(
      ImportReviewView(phase: .loaded(hostName: "Work Mac", harnesses: []), seeMore: nil) {},
      width: 520, height: 400)
    defer { empty.close() }
    #expect(try empty.shows("Nothing to import from your harnesses"))
    let connecting = OffscreenWindow(
      ImportReviewView(phase: ImportReviewStore.Phase.connecting.view, seeMore: nil) {},
      width: 520, height: 400)
    defer { connecting.close() }
    #expect(try connecting.shows("Connecting this Mac\u{2026}"))
  }
}
