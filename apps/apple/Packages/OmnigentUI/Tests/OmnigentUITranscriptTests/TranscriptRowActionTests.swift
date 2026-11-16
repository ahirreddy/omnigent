#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents
  @testable import OmnigentUITestSupport

  /// What a transcript row's own buttons and menus do: each copy lands on the pasteboard, and each
  /// disclosure shows what it kept folded.
  @Suite("Transcript rows: copy and disclosure by click", .serialized)
  @MainActor
  struct TranscriptRowActionTests {
    private typealias Fixture = TranscriptFixture

    init() {
      SystemSideEffects.reset()
    }

    private func detail(_ id: String, _ text: String, isCode: Bool = false) -> DetailSection {
      DetailSection(id: id, title: id.capitalized, text: text, isCode: isCode)
    }

    @Test("A terminal row's menu copies its command and its output")
    func terminalMenuCopies() throws {
      let row = Fixture.activityRow(
        .terminal, details: [detail("input", "make"), detail("stdout", "built")])
      let screen = transcriptScreen(ActivityRowView(row: row))
      defer { screen.close() }
      let menu = try #require(try screen.contextMenu(at: CGPoint(x: 100, y: 15)))
      try screen.choose("Copy Command", in: menu)
      #expect(copiedText() == "make")
      try screen.choose("Copy Output", in: menu)
      #expect(copiedText() == "built")
    }

    @Test("Each prose detail section copies its own text; a code section has its own Copy code")
    func detailSectionCopies() throws {
      let screen = transcriptScreen(
        DetailSectionsView(
          sections: [detail("notes", "First note"), detail("reason", "Second note")],
          rowID: "row"))
      defer { screen.close() }
      #expect(screen.controlFrames.count == 2, "one Copy per section")
      try screen.clickControl(at: 1)
      #expect(copiedText() == "Second note")
      try screen.clickControl(at: 0)
      #expect(copiedText() == "First note")
    }

    @Test("Copy diff copies every line of the diff, markers included")
    func diffCopies() throws {
      let diff = DiffSummary(
        files: ["a.swift"], added: 1, removed: 1,
        lines: [
          DiffSummary.Line(kind: .removed, text: "-old"),
          DiffSummary.Line(kind: .added, text: "+new"),
        ])
      let screen = transcriptScreen(DiffView(diff: diff))
      defer { screen.close() }
      #expect(screen.controlFrames.count == 1, "Copy diff is the only control")
      try screen.clickControl(at: 0)
      #expect(copiedText() == "-old\n+new")
    }

    @Test("The plan card opens to its todos at a click, and folds them again")
    func planCardOpens() throws {
      let plan = EventSection(
        id: "todos", title: "Plan", summary: "1 of 2",
        details: [
          DetailSection(id: "t1", title: "completed", text: "Read the code"),
          DetailSection(id: "t2", title: "pending", text: "Fix the bug"),
        ])
      let screen = transcriptScreen(PlanCard(section: plan))
      defer { screen.close() }
      #expect(try screen.shows("Plan (1/2)"))
      #expect(try !screen.shows("Fix the bug"))
      try screen.clickControl(at: 0)
      screen.settle(0.1)
      #expect(try screen.shows("Read the code"))
      #expect(try screen.shows("Fix the bug"))
      try screen.clickControl(at: 0)
      screen.settle(0.1)
      #expect(try !screen.shows("Fix the bug"))
    }

    @Test("An equation's menu copies its TeX source")
    func mathCopiesTeX() throws {
      let screen = transcriptScreen(
        MathBlockView(tex: "x^2 + y^2").environment(\.markdownBlockIsOpen, true), height: 120)
      defer { screen.close() }
      let menu = try #require(try screen.firstContextMenu())
      #expect(titles(of: menu) == ["Copy TeX"])
      try screen.choose("Copy TeX", in: menu)
      #expect(copiedText() == "x^2 + y^2")
    }

    @Test("A message's Share is offered for its text")
    func messageShareIsOffered() throws {
      let screen = transcriptScreen(
        MessageRowView(row: Fixture.answer("a", "Body"), decoration: MessageDecoration()))
      defer { screen.close() }
      let menu = try #require(try screen.firstContextMenu())
      let share = try #require(menu.items.first { $0.title == "Share" })
      #expect(share.isEnabled)
    }
  }
#endif
