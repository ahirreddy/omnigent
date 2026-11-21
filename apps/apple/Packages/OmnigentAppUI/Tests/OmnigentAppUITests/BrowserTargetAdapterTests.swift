import Foundation
import OmnigentCoreFFI
import OmnigentTestSupport
import OmnigentUIComponents
import Testing

@testable import OmnigentAppUI
@testable import OmnigentStores

/// The session's browser choice as the chip shows it, and a refused switch as it reads.
@MainActor
@Suite("Browser target adapter", .serialized, .timeLimit(.minutes(1)))
struct BrowserTargetAdapterTests {
  private let sessionPath = "/v1/sessions/conv_a"

  private func panel(offersAgentBrowser: Bool, patch: HttpResponse) async throws
    -> SessionPanelStore
  {
    let server = AppServer()
    let features = #"{"agent_browser_devtools":\#(offersAgentBrowser)}"#
    server.route(
      "/v1/info",
      .json(#"{"single_user":true,"accounts_enabled":false,"features":\#(features)}"#))
    server.route(
      sessionPath, method: "GET",
      .json(#"{"id":"conv_a","labels":{"omnigent.browser_target":"local"}}"#))
    server.route(sessionPath, method: "PATCH", patch)
    let connection = try await signedInStore(server)
    let panel = try #require(connection.makePanelStore("conv_a"))
    await panel.loadBrowserTarget()
    return panel
  }

  @Test("No chip or chooser until the server offers the agent browser")
  func hidden() async throws {
    let panel = try await panel(offersAgentBrowser: false, patch: .json("{}"))
    #expect(BrowserTargetAdapter.state(panel, isShared: false) == nil)
    #expect(BrowserTargetAdapter.chooser(panel, report: { _ in }) == nil)
    #expect(BrowserTargetAdapter.state(nil, isShared: false) == nil)
  }

  @Test("The chip shows the label; a shared session turns This Mac off with the reason")
  func shown() async throws {
    let panel = try await panel(offersAgentBrowser: true, patch: .json("{}"))
    #expect(
      BrowserTargetAdapter.state(panel, isShared: false) == BrowserTargetState(choice: .local))
    let shared = try #require(BrowserTargetAdapter.state(panel, isShared: true))
    #expect(shared.localUnavailableReason == BrowserTargetState.ownerOnly)
  }

  @Test("A refused switch reports the owner-only rule and keeps the old choice")
  func refused() async throws {
    let panel = try await panel(
      offersAgentBrowser: true, patch: .json(#"{"detail":"owner only"}"#, status: 403))
    final class Reports { var messages: [String] = [] }
    let reports = Reports()
    let choose = try #require(BrowserTargetAdapter.chooser(panel) { reports.messages.append($0) })
    choose(.remote)
    try await eventually("the refusal is reported") { !reports.messages.isEmpty }
    #expect(reports.messages == [BrowserTargetState.ownerOnly])
    #expect(panel.browserTarget == .local)
  }

  @Test("Choices map one to one onto the core's targets")
  func mapping() {
    for choice in BrowserTargetChoice.allCases {
      #expect(BrowserTargetAdapter.choice(BrowserTargetAdapter.target(choice)) == choice)
    }
  }
}
