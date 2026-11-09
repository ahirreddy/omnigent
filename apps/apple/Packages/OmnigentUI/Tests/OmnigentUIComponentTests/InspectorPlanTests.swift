#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  @Suite("Inspector: the plan accordion", .serialized)
  @MainActor
  struct InspectorPlanTests {
    private let plan = EventSection(
      id: "todos", title: "Plan", summary: "",
      details: [
        DetailSection(id: "1", title: "Completed: first", text: "Read the code"),
        DetailSection(id: "2", title: "In progress: second", text: "Write the test"),
        DetailSection(id: "3", title: "Pending: third", text: "Ship it"),
      ])

    private func accordion(_ section: EventSection, width: LayoutWidth = .regular)
      -> OffscreenWindow<AnyView>
    {
      OffscreenWindow(
        AnyView(PlanAccordion(section: section).environment(\.layoutWidth, width)), width: 600,
        height: 400)
    }

    @Test("Folded, it shows progress and the current step; opened, it lists every step")
    func foldAndOpen() throws {
      let screen = accordion(plan)
      defer { screen.close() }
      #expect(try screen.shows("Plan \u{00B7} 1 of 3 done"))
      #expect(try screen.shows("Write the test"))
      #expect(try !screen.shows("Read the code"))
      #expect(try !screen.shows("Ship it"))

      try screen.clickControl(at: 0)
      for step in ["Read the code", "Write the test", "Ship it"] {
        #expect(try screen.shows(step))
      }
      try screen.clickControl(at: 0)
      screen.settle(0.3)
      #expect(try !screen.shows("Ship it"))
    }

    @Test("With nothing in progress, folded shows only the count")
    func nothingCurrent() throws {
      var section = plan
      section.details = [section.details[0], section.details[2]]
      let screen = accordion(section)
      defer { screen.close() }
      #expect(try screen.shows("Plan \u{00B7} 1 of 2 done"))
      #expect(try !screen.shows("Ship it"))
    }

    @Test("An empty plan reads as zero of zero, without dividing by nothing")
    func emptyPlan() throws {
      var section = plan
      section.details = []
      let screen = accordion(section)
      defer { screen.close() }
      #expect(try screen.shows("Plan \u{00B7} 0 of 0 done"))
    }

    @Test("A compact window gives the card a narrower margin")
    func compactMargin() throws {
      let regular = accordion(plan)
      defer { regular.close() }
      let compact = accordion(plan, width: .compact)
      defer { compact.close() }
      let regularFrame = try #require(regular.controlFrames.first)
      let compactFrame = try #require(compact.controlFrames.first)
      #expect(compactFrame.width > regularFrame.width)
    }

    @Test("Each step's state draws differently")
    func rowStates() throws {
      let pictures = try [SectionReading.TodoState.completed, .inProgress, .pending].map { state in
        try RenderSupport.picture(
          TodoRow(todo: SectionReading.Todo(id: "t", state: state, text: "Step")), width: 200,
          height: 40)
      }
      #expect(Set(pictures).count == 3)
    }

    @Test("The ring turns amber near a budget's end, and shows done at the end of a plan")
    func ring() throws {
      func picture(_ fraction: Double, warns: Bool) throws -> Data {
        try RenderSupport.picture(
          ProgressRing(fraction: fraction, warnsNearFull: warns), width: 30, height: 30)
      }
      #expect(try picture(0.9, warns: true) != picture(0.9, warns: false))
      #expect(try picture(0.5, warns: true) == picture(0.5, warns: false))
      #expect(try picture(1, warns: false) != picture(1, warns: true))
    }
  }
#endif
