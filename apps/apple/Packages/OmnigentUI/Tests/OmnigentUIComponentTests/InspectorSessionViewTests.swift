#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  @MainActor
  private func sessionHeader(_ settings: SessionSettings? = nil, failure: String? = nil)
    -> SessionHeader
  {
    SessionHeader(id: "sess-1", title: "S", failureMessage: failure, settings: settings)
  }

  @MainActor
  func inspectorPanel(
    _ sections: [EventSection] = [], settings: SessionSettings? = nil, failure: String? = nil,
    rows: [Row] = [], actions: ConversationActions = ConversationActions()
  ) -> OffscreenWindow<AnyView> {
    SystemSideEffects.reset()
    let state = ConversationViewState(
      header: sessionHeader(settings, failure: failure), rows: rows, sections: sections)
    let view = SessionInspectorView(state: state, actions: actions).frame(
      width: 500, height: 1_100)
    return OffscreenWindow(AnyView(view), width: 500, height: 1_100)
  }

  @Suite("Inspector: the session panel", .serialized)
  @MainActor
  struct InspectorSessionViewTests {
    @Test("An empty session shows only its status and id; every other section hides")
    func emptyHides() throws {
      let screen = inspectorPanel()
      defer { screen.close() }
      #expect(try screen.shows("Session"))
      #expect(try screen.shows("Status"))
      #expect(try screen.shows("sess-1"))
      for hidden in [
        "Harness", "Usage", "Plan", "Viewers", "Changed Files", "Subagents", "Environment", "Other",
        "Last failure",
      ] {
        #expect(try !screen.shows(hidden), "\(hidden)")
      }
    }

    @Test("Sections with nothing in them hide too")
    func emptySections() throws {
      let screen = inspectorPanel([
        EventSection(id: "todos", title: "Plan", summary: ""),
        EventSection(id: "presence", title: "Viewers", summary: ""),
      ])
      defer { screen.close() }
      #expect(try !screen.shows("Plan"))
      #expect(try !screen.shows("Viewers"))
    }

    @Test("Copy puts the session id on the pasteboard")
    func copyID() throws {
      let screen = inspectorPanel()
      defer { screen.close() }
      try screen.clickControl(at: 0)
      #expect(SystemSideEffects.pasteboard.string(forType: .string) == "sess-1")
    }

    @Test("Settings show harness, model, effort, routing, host and runner")
    func settings() throws {
      let screen = inspectorPanel(
        settings: SessionSettings(
          harness: "claude", baseModel: "opus", reasoningEffort: .value(value: "high"),
          hostOnline: true,
          runnerOnline: false, routingMode: "fast"))
      defer { screen.close() }
      for text in ["Harness", "opus", "High", "Fast", "Online", "Offline"] {
        #expect(try screen.shows(text), "\(text)")
      }
    }

    @Test("Unreported settings say so")
    func unreported() throws {
      let screen = inspectorPanel(settings: SessionSettings())
      defer { screen.close() }
      #expect(try screen.shows("Not reported"))
      #expect(try screen.shows("Unknown"))
      #expect(try !screen.shows("Routing"))
    }

    @Test("A harness default is named, and an unbound runner says so")
    func harnessDefault() throws {
      let screen = inspectorPanel(
        settings: SessionSettings(
          reasoningEffort: .harnessDefault, hostOnline: false, runnerOnline: true,
          runnerBound: false))
      defer { screen.close() }
      #expect(try screen.shows("Harness default"))
      #expect(try screen.shows("Not bound"))
      #expect(try screen.shows("Offline"))
      #expect(try !screen.shows("Online"))
    }

    @Test("Runner online")
    func runnerOnline() throws {
      let screen = inspectorPanel(settings: SessionSettings(hostOnline: false, runnerOnline: true))
      defer { screen.close() }
      #expect(try screen.shows("Online"))
    }

    @Test("Permission, approval and collaboration show their summaries")
    func accessRows() throws {
      let screen = inspectorPanel([
        EventSection(id: "permission", title: "Permission", summary: "Ask first"),
        EventSection(id: "approval", title: "Approval", summary: "Auto"),
        EventSection(id: "collaboration", title: "Collaboration", summary: "Shared"),
      ])
      defer { screen.close() }
      #expect(try screen.shows("Ask first"))
      #expect(try screen.shows("Auto"))
      #expect(try screen.shows("Shared"))
    }

    @Test("The last failure shows")
    func failure() throws {
      let screen = inspectorPanel(failure: "Out of memory")
      defer { screen.close() }
      #expect(try screen.shows("Last failure"))
      #expect(try screen.shows("Out of memory"))
    }

    private func usage(_ details: [(String, String)]) -> EventSection {
      EventSection(
        id: "usage", title: "Usage", summary: "",
        details: details.map { DetailSection(id: $0.0, title: "", text: $0.1) })
    }

    @Test("Usage shows the context used, cost and each model's line")
    func usageWithWindow() throws {
      let screen = inspectorPanel([
        usage([
          ("context_tokens", "500"), ("context_window", "1000"), ("total_cost_usd", "1.5"),
          ("usage_by_model", "opus: 1\nsonnet: 2"),
        ])
      ])
      defer { screen.close() }
      #expect(try screen.shows("500 of 1,000 context tokens"))
      #expect(try screen.shows("$1.50"))
      #expect(try screen.shows("opus: 1"))
      #expect(try screen.shows("sonnet: 2"))
    }

    @Test("Without a window usage shows the tokens alone; near full it warns")
    func usageWithoutWindow() throws {
      let screen = inspectorPanel([usage([("context_tokens", "500")])])
      defer { screen.close() }
      #expect(try screen.shows("Context tokens"))
      #expect(try screen.shows("500"))
      let nearlyFull = inspectorPanel([
        usage([("context_tokens", "900"), ("context_window", "1000")])
      ])
      defer { nearlyFull.close() }
      #expect(try nearlyFull.shows("900 of 1,000 context tokens"))
    }

    @Test("The plan lists its todos by state")
    func plan() throws {
      let screen = inspectorPanel([
        EventSection(
          id: "todos", title: "Plan", summary: "",
          details: [
            DetailSection(id: "a", title: "Completed: x", text: "Old task"),
            DetailSection(id: "b", title: "In progress: x", text: "Current task"),
            DetailSection(id: "c", title: "Pending: x", text: "Next task"),
          ])
      ])
      defer { screen.close() }
      #expect(try screen.shows("Plan"))
      #expect(try screen.shows("Old task"))
      #expect(try screen.shows("Current task"))
      #expect(try screen.shows("Next task"))
    }

    @Test("Viewers show as active or idle")
    func viewers() throws {
      let screen = inspectorPanel([
        EventSection(
          id: "presence", title: "Viewers", summary: "",
          details: [
            DetailSection(id: "a", title: "Ada", text: "Active"),
            DetailSection(id: "b", title: "Grace", text: "Idle"),
          ])
      ])
      defer { screen.close() }
      #expect(try screen.shows("Viewers"))
      #expect(try screen.shows("Ada"))
      #expect(try screen.shows("Active"))
      #expect(try screen.shows("Idle"))
    }
  }
#endif
