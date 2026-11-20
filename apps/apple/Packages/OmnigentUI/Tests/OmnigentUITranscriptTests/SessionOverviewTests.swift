import Testing

@testable import OmnigentUIComponents

#if os(macOS)
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI

  @testable import OmnigentUITestSupport
#endif

/// The session overview (the web's `session_overview`): the cost chip, the overview's rows read
/// from the core's usage section, and the agents' cost tags.
@Suite("Session overview", .serialized)
@MainActor
struct SessionOverviewTests {
  private func usage(
    cost: String? = "$0.05", models: String? = "dear\t$0.05\nfree\t", tokens: String? = "12400"
  )
    -> EventSection
  {
    var details: [DetailSection] = []
    if let cost {
      details.append(DetailSection(id: "overview_cost", title: "Session cost", text: cost))
    }
    if let models {
      details.append(DetailSection(id: "overview_models", title: "Cost by model", text: models))
    }
    if let tokens {
      details.append(DetailSection(id: "overview_tokens", title: "Tokens", text: tokens))
    }
    return EventSection(id: "usage", title: "Usage", summary: "", details: details)
  }

  @Test("the overview reads the session's cost, each model's and the tokens")
  func reading() {
    let overview = SessionOverviewReading(usage())
    #expect(overview.cost == "$0.05")
    #expect(overview.models.map(\.model) == ["dear", "free"])
    #expect(overview.models.map(\.cost) == ["$0.05", ""], "an unpriced model shows no cost")
    #expect(overview.tokens == 12_400)
    #expect(SessionOverviewReading.tokens(842) == "842")
    #expect(SessionOverviewReading.tokens(12_400) == "12.4K")
    let empty = SessionOverviewReading(nil)
    #expect(empty.cost == nil && empty.models.isEmpty && empty.tokens == nil)
  }

  #if os(macOS)
    private func chip(_ offers: Bool, sections: [EventSection]) -> OffscreenWindow<AnyView> {
      var state = PreviewData.conversation
      state.sections = sections
      return transcriptScreen(
        SessionCostChip(state: state, costs: nil).environment(\.offersSessionOverview, offers),
        width: 200, height: 60)
    }

    @Test("the chip shows the session's cost only where the server offers the overview")
    func chipShows() throws {
      let offered = chip(true, sections: [usage()])
      defer { offered.close() }
      #expect(try offered.shows("$0.05"))
      let unknown = chip(true, sections: [])
      defer { unknown.close() }
      #expect(try unknown.shows("\u{2014}"))
      let off = chip(false, sections: [usage()])
      defer { off.close() }
      #expect(try !off.shows("$0.05"))
    }
  #endif
}
