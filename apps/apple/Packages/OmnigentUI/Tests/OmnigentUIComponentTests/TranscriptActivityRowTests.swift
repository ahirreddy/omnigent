#if os(macOS)
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  @Suite("Transcript activity rows", .serialized)
  @MainActor
  struct TranscriptActivityRowTests {
    private typealias Fixture = TranscriptFixture

    private func detail(_ id: String, _ text: String, isCode: Bool = false) -> DetailSection {
      DetailSection(id: id, title: id.capitalized, text: text, isCode: isCode)
    }

    @Test("A terminal row opens to its output, says nothing runs here, and closes")
    func terminalOpens() throws {
      let row = Fixture.activityRow(
        .terminal,
        details: [detail("input", "make"), detail("stdout", "built"), detail("stderr", "warned")])
      let screen = transcriptScreen(ActivityRowView(row: row))
      defer { screen.close() }
      #expect(try screen.shows("make"))
      #expect(try !screen.shows("built"))
      try screen.clickControl(at: 0)
      #expect(try screen.shows("built"))
      #expect(try screen.shows("warned"))
      #expect(try screen.shows("Recorded output. Nothing runs on this device."))
      try screen.clickControl(at: 0)
      #expect(try !screen.shows("built"))
    }

    @Test("A terminal row without a command or output names what it has, with nothing to open")
    func terminalPlaceholders() throws {
      let empty = transcriptScreen(ActivityRowView(row: Fixture.activityRow(.terminal)))
      defer { empty.close() }
      #expect(try empty.shows("Terminal (no output)"))
      #expect(empty.controlFrames.isEmpty)

      let outputOnly = transcriptScreen(
        ActivityRowView(row: Fixture.activityRow(.terminal, details: [detail("stdout", "built")])))
      defer { outputOnly.close() }
      #expect(try outputOnly.shows("Terminal output"))
      #expect(outputOnly.controlFrames.count == 1)
    }

    @Test("A terminal row's menu offers only what it has to copy")
    func terminalMenu() throws {
      let row = Fixture.activityRow(
        .terminal, details: [detail("input", "make"), detail("stdout", "built")])
      let screen = transcriptScreen(ActivityRowView(row: row))
      defer { screen.close() }
      let menu = try screen.contextMenu(at: CGPoint(x: 100, y: 15))
      #expect(menu?.items.map(\.title) == ["Copy Command", "Copy Output"])
    }

    @Test("A retry row says what is being retried, live or settled")
    func retry() throws {
      for isStreaming in [true, false] {
        let screen = transcriptScreen(
          ActivityRowView(
            row: Fixture.activityRow(
              .retry, title: "Retrying", summary: "Attempt 2", isStreaming: isStreaming)))
        defer { screen.close() }
        #expect(try screen.shows("Retrying"))
        #expect(try screen.shows("Attempt 2"))
      }
    }

    @Test("Compaction opens to what it kept")
    func compaction() throws {
      let row = Fixture.activityRow(
        .compaction, title: "Context compacted", details: [detail("summary", "Kept the plan")])
      let screen = transcriptScreen(ActivityRowView(row: row))
      defer { screen.close() }
      #expect(try screen.shows("Context compacted"))
      #expect(try !screen.shows("Kept the plan"))
      try screen.clickControl(at: 0)
      #expect(try screen.shows("Kept the plan"))
    }

    @Test("A side question shows both sides and opens in its own tab")
    func sideChat() throws {
      let log = HostLog()
      var actions = ConversationActions()
      actions.openSideChat = { log.add($0.id) }
      let row = Fixture.activityRow(
        .sidechat, summary: "Unused",
        details: [detail("question", "Why?"), detail("answer", "Because.")])
      let screen = transcriptScreen(ActivityRowView(row: row), actions: actions)
      defer { screen.close() }
      #expect(try screen.shows("Side question"))
      #expect(try screen.shows("Why?"))
      #expect(try screen.shows("Because."))
      #expect(try !screen.shows("Unused"))
      try screen.clickControl(at: screen.controlFrames.count - 1)
      #expect(log.entries == ["row"])
    }

    @Test("A side question with no answer yet shows its summary, and no tab without a host")
    func sideChatPending() throws {
      let row = Fixture.activityRow(.sidechat, summary: "Thinking it over")
      let screen = transcriptScreen(ActivityRowView(row: row))
      defer { screen.close() }
      #expect(try screen.shows("Thinking it over"))
      #expect(screen.controlFrames.isEmpty)
    }

    @Test("An item this app doesn't know says so, with its safe text, whether or not it opens")
    func unknown() throws {
      let bare = transcriptScreen(
        ActivityRowView(row: Fixture.activityRow(.unknown, title: "")))
      defer { bare.close() }
      #expect(try bare.shows("Unsupported item"))
      #expect(try bare.shows("Unsupported"))
      #expect(try bare.shows("This item type is not supported in the app yet."))
      #expect(bare.controlFrames.isEmpty)

      let detailed = transcriptScreen(
        ActivityRowView(
          row: Fixture.activityRow(
            .unknown, title: "Strange", summary: "Safe text", details: [detail("raw", "Payload")])))
      defer { detailed.close() }
      try detailed.clickControl(at: 0)
      #expect(try detailed.shows("Safe text"))
      #expect(try detailed.shows("Payload"))
    }

    @Test("A row with no activity still shows its text rather than vanishing")
    func noActivity() throws {
      let screen = transcriptScreen(
        ActivityRowView(row: Row(id: "row", role: .tool, text: "Bare text")))
      defer { screen.close() }
      #expect(try screen.shows("Activity"))
      #expect(try screen.shows("Bare text"))
    }

    @Test("A policy denial's reason shows even with no details to open")
    func summaryWithoutDetails() throws {
      let screen = transcriptScreen(
        ActivityRowView(
          row: Fixture.activityRow(
            .policy, title: "Denied", summary: "Writes to main are blocked", isFailure: true)))
      defer { screen.close() }
      #expect(try screen.shows("Denied"))
      #expect(try screen.shows("Writes to main are blocked"))
      #expect(screen.controlFrames.isEmpty)
    }

    @Test("Each other kind shows its title and status, and opens to its details")
    func generic() throws {
      let kinds: [ActivityKind] = [
        .routing, .command, .resource, .file, .policy, .clientTask, .browser, .toolCall,
        .toolResult, .nativeTool,
      ]
      for kind in kinds {
        let row = Fixture.activityRow(
          kind, title: "Headline", status: "in_progress", details: [detail("more", "Inside")])
        let screen = transcriptScreen(ActivityRowView(row: row))
        defer { screen.close() }
        #expect(try screen.shows("Headline"), "\(kind)")
        #expect(try screen.shows("In Progress"), "\(kind)")
        #expect(try !screen.shows("Inside"), "\(kind)")
        try screen.clickControl(at: 0)
        #expect(try screen.shows("Inside"), "\(kind)")
        let isRecordedOnly = kind == .browser || kind == .clientTask
        #expect(
          try screen.shows("Recorded activity only. Nothing runs on this device.")
            == isRecordedOnly, "\(kind)")
      }
    }

    @Test("A failed row reads as failed and hides its raw status")
    func genericFailure() throws {
      let row = Fixture.activityRow(.file, title: "Write", status: "failed", isFailure: true)
      let screen = transcriptScreen(ActivityRowView(row: row))
      defer { screen.close() }
      #expect(try screen.shows("Write"))
      #expect(try !screen.shows("Failed"))
    }

    @Test("Every kind has its own symbol and name")
    func kindNames() {
      let names = ActivityKind.allCases.map(\.displayName)
      #expect(Set(names).count == ActivityKind.allCases.count)
      #expect(ActivityKind.allCases.allSatisfy { !$0.systemImage.isEmpty })
      #expect(ActivityKind.unknown.displayName == "Unsupported item")
    }

    @Test("Reasoning opens while it streams, folds when it settles, and names how long it took")
    func reasoning() throws {
      #expect(ReasoningRowView.title(isStreaming: true, duration: nil) == "Thinking\u{2026}")
      #expect(
        ReasoningRowView.title(isStreaming: false, duration: nil) == "Thought for a few seconds")
      #expect(ReasoningRowView.title(isStreaming: false, duration: 2.5).hasPrefix("Thought for 2"))

      let live = transcriptScreen(
        ActivityRowView(
          row: Fixture.activityRow(
            .reasoning, summary: "Short", details: [detail("summary", "Weighing it")],
            isStreaming: true)))
      defer { live.close() }
      #expect(try live.shows("Thinking\u{2026}"))
      #expect(try live.shows("Weighing it"))

      let settled = transcriptScreen(
        ActivityRowView(
          row: Fixture.activityRow(.reasoning, details: [detail("summary", "Weighed it")])))
      defer { settled.close() }
      #expect(try settled.shows("Thought for a few seconds"))
      #expect(try !settled.shows("Weighed it"))
      try settled.clickControl(at: 0)
      #expect(try settled.shows("Weighed it"))
    }

    @Test("Detail sections past the limit are counted, not dropped silently")
    func detailLimit() throws {
      let sections = (0..<3).map { detail("s\($0)", "Text \($0)") }
      let screen = transcriptScreen(
        DetailSectionsView(sections: sections, rowID: "row", maxSections: 2))
      defer { screen.close() }
      #expect(try screen.shows("Text 1"))
      #expect(try !screen.shows("Text 2"))
      #expect(try screen.shows("1 more sections are available in the web app."))
    }

    @Test("Code sections draw as code, and a diff in one draws as a diff")
    func detailCode() throws {
      let patch = "--- a/x\n+++ b/x\n@@ -1 +1 @@\n-old\n+new"
      let screen = transcriptScreen(
        DetailSectionsView(
          sections: [
            detail("code", "print(1)", isCode: true), detail("patch", patch, isCode: true),
          ],
          rowID: "row"))
      defer { screen.close() }
      #expect(try screen.shows("print(1)"))
      #expect(try screen.shows("Code"))
      #expect(try screen.shows("+new"))
      #expect(try screen.shows("\u{2212}1"))
    }
  }
#endif
